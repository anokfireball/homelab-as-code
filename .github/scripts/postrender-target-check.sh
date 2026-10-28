#!/usr/bin/env bash
# Fails when a HelmRelease kustomize postRenderer patch with a `target` selects
# nothing in that release's rendered output. Kustomize treats an empty selection
# as success, so a stale target silently disables its patch.
#
#   postrender-target-check.sh FLATE_BIN REPO_DIR
set -euo pipefail

flate_bin=${1:?flate binary required}
repo=$(cd "${2:?repo dir required}" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. Targets per HelmRelease that has postRenderers, one JSON object per line.
find "$repo/flux" -name '*.yaml' -print0 | sort -z |
  while IFS= read -r -d '' f; do
    yq -o json -I 0 'select(.kind == "HelmRelease" and .spec.postRenderers != null)
      | {"ns": (.metadata.namespace // "default"), "hr": .metadata.name,
         "targets": [.spec.postRenderers[].kustomize.patches[]? | .target]}' "$f" |
      jq -c --arg file "${f#"$repo"/}" 'select(.hr != null) | . + {file: $file}'
  done >"$work/targets.jsonl"

# 2. Pre-patch copy: the same tree with every HelmRelease's postRenderers removed.
#    flate has no switch that skips postRenderers, so this copy is the only way
#    to see the objects kustomize receives.
mkdir "$work/tree"
tar -C "$repo" --exclude=.git -cf - . | tar -C "$work/tree" -xf -
jq -r '.file' "$work/targets.jsonl" | sort -u | while IFS= read -r f; do
  yq -i 'with(select(.kind == "HelmRelease"); del(.spec.postRenderers))' "$work/tree/$f"
done

# 3. Every targeted patch must select at least one object of its release.
python3 - "$flate_bin" "$work/tree" "$work/targets.jsonl" <<'PY'
import json, re, subprocess, sys

flate, tree, targets_path = sys.argv[1:4]
FIELDS = ("group", "version", "kind", "name", "namespace")

def signature(t):
    return " ".join(f"{k}={t[k]}" for k in FIELDS if t.get(k))

def selects(t, obj):
    api = obj.get("apiVersion", "")
    group, version = api.rsplit("/", 1) if "/" in api else ("", api)
    meta = obj.get("metadata") or {}
    have = {"group": group, "version": version, "kind": obj.get("kind", ""),
            "name": meta.get("name", ""), "namespace": meta.get("namespace") or "default"}
    return all(not t.get(k) or re.fullmatch(f"(?:{t[k]})", have[k]) for k in FIELDS)

# Each error is (file, message); file is None when no single file is responsible.
errors, expected = [], {}
for line in open(targets_path):
    entry = json.loads(line)
    key = f'{entry["ns"]}/{entry["hr"]}'
    for t in entry["targets"]:
        if t is None:
            continue  # targetless patch: kustomize already fails when its object is missing
        if t.get("labelSelector") or t.get("annotationSelector"):
            errors.append((entry["file"], f'{key}: label/annotation selectors are not supported by this check'))
            continue
        expected.setdefault((key, signature(t)), (entry["file"], t))

rendered, failed = {}, set()
def objects(key, file):
    # `flate build hr NAME -n NS` reconciles every HelmRelease in NS and prints only NAME's
    # objects, so an unrelated release that fails to render (for example a flaky OCI source)
    # sets a non-zero exit code. Judge the run by this release's own output and errors.
    if key not in rendered:
        ns, name = key.split("/", 1)
        run = subprocess.run(
            [flate, "build", "hr", name, "-n", ns, "--path", tree, "-o", "json",
             "--allow-missing-secrets", "--skip-crds=false", "--skip-secrets=false", "--no-progress"],
            capture_output=True, text=True)
        own_failure = re.search(rf"✗\s+HelmRelease\s+{re.escape(key)}\s", run.stderr)
        try:
            docs = json.loads(run.stdout) if run.stdout.strip() else []
        except json.JSONDecodeError:
            docs = None
        if own_failure or docs is None or (run.returncode and not docs):
            errors.append((file, f"{key}: flate build hr failed: {run.stderr.strip()[-400:]}"))
            failed.add(key)
            docs = []
        rendered[key] = docs if isinstance(docs, list) else [docs]
    return rendered[key]

for (key, sig), (file, t) in sorted(expected.items()):
    hits = sum(1 for o in objects(key, file) if selects(t, o))
    print(f"{hits:3d}  {key}  [{sig}]")
    if hits == 0 and key not in failed:
        errors.append((file, f"{key}: target [{sig}] selects no rendered object"))

def annotate(file, message):
    return f"::error file={file}::{message}" if file else f"::error::{message}"

if errors:
    for file, message in errors:
        print(annotate(file, message))
    sys.exit(1)
print(f"OK: all {len(expected)} postRenderer targets select at least one object.")
PY
