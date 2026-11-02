#!/usr/bin/env bash
# Checks the democratic-csi sig-storage sidecars against the chart that renders
# them.
#
#   csi-sidecar-compat.sh [BASE_SHA]
#
# Each HelmRelease is rendered from its values with the pinned chart. For every
# sidecar in the rendered controller Deployment and node DaemonSet, the image's
# --help must list each flag the chart passes, and the controller's
# ServiceAccount must hold each rule upstream's RBAC manifest asks of that
# sidecar. Gaps pass only where listed below. With BASE_SHA, a sidecar tag change
# also warns about feature gates whose default flipped between the two tags.
set -euo pipefail

file=flux/system/app-controllers/democratic-csi.yaml
repo_file=flux/repositories/democratic-csi.yaml
base_sha="${1:-}"

# A PR that deletes the file has nothing left to check.
[ -f "$file" ] || exit 0

# Accepted RBAC gaps, one array per gap. An entry is "image group resource verbs
# [--flag=value]": "*" matches any group, resource or verb, and an entry with a
# flag applies only to a sidecar whose args contain it.
# Volume group snapshots, which the chart does not grant: accepted only with the snapshotter gate off.
gap_groupsnapshot=("csi-snapshotter groupsnapshot.storage.k8s.io * * --feature-gates=CSIVolumeGroupSnapshot=false")
# VolumeAttributesClass reads: the driver does not advertise MODIFY_VOLUME.
gap_vac=(
  "csi-provisioner storage.k8s.io volumeattributesclasses get,list,watch"
  "csi-resizer storage.k8s.io volumeattributesclasses get,list,watch"
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/help" "$work/rbac" "$work/features"
status=0
versions=()

repo_url="$(yq '.spec.url // ""' "$repo_file")"
if [ -z "$repo_url" ]; then
  echo "::error file=$repo_file::no spec.url for the democratic-csi HelmRepository"
  exit 1
fi

# Field $2 of the HelmRelease named $1.
hr() {
  NAME="$1" yq "select(.kind == \"HelmRelease\" and .metadata.name == env(NAME)) | $2" "$file"
}

mapfile -t releases < <(yq -N 'select(.kind == "HelmRelease") | .metadata.name' "$file")
if [ "${#releases[@]}" -eq 0 ]; then
  echo "::error file=$file::no HelmRelease in file"
  exit 1
fi

for name in "${releases[@]}"; do
  dir="$work/$name"
  mkdir -p "$dir"
  chart="$(hr "$name" '.spec.chart.spec.chart')"
  version="$(hr "$name" '.spec.chart.spec.version')"
  ns="$(hr "$name" '.metadata.namespace')"
  versions+=("$version")

  hr "$name" '.spec.values' > "$dir/values.yaml"
  if ! helm template "$name" "$chart" --repo "$repo_url" --version "$version" \
    --namespace "$ns" -f "$dir/values.yaml" > "$dir/rendered.yaml"; then
    echo "::error file=$file::$name: helm template $chart $version failed"
    status=1
    continue
  fi
  yq -o=json -I=0 '.' "$dir/rendered.yaml" > "$dir/rendered.jsonl"

  # Lists the sidecars and writes their help and RBAC fetch targets to sidecars.tsv.
  python3 - "$dir/rendered.jsonl" "$dir" "$name" "$ns" "$file" "$work" <<'PY' || { status=1; continue; }
import json, os, re, sys

rendered, out_dir, release, ns, file_, work = sys.argv[1:7]
PREFIX = "registry.k8s.io/sig-storage/"
# Sidecar image name -> upstream repo under kubernetes-csi/.
UPSTREAM = {
    "csi-attacher": "external-attacher",
    "csi-provisioner": "external-provisioner",
    "csi-resizer": "external-resizer",
    "csi-snapshotter": "external-snapshotter",
    "csi-node-driver-registrar": "node-driver-registrar",
}
# Controller sidecars with RBAC, and the manifest upstream ships at the tag.
RBAC = {
    "external-attacher": "deploy/kubernetes/rbac.yaml",
    "external-provisioner": "deploy/kubernetes/rbac.yaml",
    "external-resizer": "deploy/kubernetes/rbac.yaml",
    "external-snapshotter": "deploy/kubernetes/csi-snapshotter/rbac-csi-snapshotter.yaml",
}
failed = False


def fail(msg):
    global failed
    failed = True
    print(f"::error file={file_}::{msg}")


def clean(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


with open(rendered) as f:
    docs = [json.loads(line) for line in f if line.strip() not in ("", "null")]

sidecars = []
for d in docs:
    kind = d.get("kind")
    if kind not in ("Deployment", "DaemonSet"):
        continue
    scope = "controller" if kind == "Deployment" else "node"
    pod = d["spec"]["template"]["spec"]
    sa = pod.get("serviceAccountName") or pod.get("serviceAccount") or "default"
    for c in pod.get("containers") or []:
        ref = c.get("image", "")
        if not ref.startswith(PREFIX):
            continue
        m = re.match(r"([^:@]+)(?::([^@]+))?", ref[len(PREFIX):])
        if not m:
            fail(f"{release}: cannot parse image {ref}")
            continue
        name, tag = m.group(1), m.group(2)
        if name not in UPSTREAM:
            fail(f"{release}: {ref} is not a known sidecar; add it to csi-sidecar-compat.sh")
            continue
        if not tag:
            fail(f"{release}: {ref} has no tag")
            continue
        repo = UPSTREAM[name]
        rbac_url = rbac_file = None
        if scope == "controller" and repo in RBAC:
            rbac_url = f"https://raw.githubusercontent.com/kubernetes-csi/{repo}/{tag}/{RBAC[repo]}"
            rbac_file = os.path.join(work, "rbac", clean(rbac_url) + ".jsonl")
        sidecars.append({
            "scope": scope,
            "container": c.get("name", ""),
            "name": name,
            "ref": ref,
            "repo": repo,
            "tag": tag,
            "args": c.get("args") or [],
            "sa": sa,
            "help_file": os.path.join(work, "help", clean(ref)),
            "rbac_url": rbac_url,
            "rbac_file": rbac_file,
        })

if not sidecars:
    fail(f"{release}: no sig-storage sidecars rendered")
with open(os.path.join(out_dir, "plan.json"), "w") as f:
    json.dump({"release": release, "ns": ns, "rendered": rendered, "sidecars": sidecars}, f)
with open(os.path.join(out_dir, "sidecars.tsv"), "w") as f:
    for s in sidecars:
        f.write("\t".join([s["ref"], s["help_file"], s["rbac_url"] or "-", s["rbac_file"] or "-"]) + "\n")
sys.exit(1 if failed else 0)
PY

  while IFS=$'\t' read -r ref help_file rbac_url rbac_file; do
    if [ ! -e "$help_file" ]; then
      out="$(docker run --rm "$ref" --help 2>&1 < /dev/null || true)"
      # Some images print usage only for -h.
      if ! grep -qi usage <<<"$out"; then
        out="$(docker run --rm "$ref" -h 2>&1 < /dev/null || true)"
      fi
      printf '%s\n' "$out" > "$help_file"
    fi
    if [ "$rbac_url" != - ] && [ ! -e "$rbac_file" ]; then
      if curl -fsSL --retry 5 --retry-all-errors -o "$work/rbac.yaml" "$rbac_url"; then
        yq -o=json -I=0 '.' "$work/rbac.yaml" > "$rbac_file"
      else
        echo "::error file=$file::$name: cannot fetch $rbac_url; find the RBAC manifest at this tag"
        status=1
      fi
    fi
  done < "$dir/sidecars.tsv"

  python3 - "$dir/plan.json" "$file" "${gap_groupsnapshot[@]}" "${gap_vac[@]}" <<'PY' || status=1
import json, os, re, sys

plan_path, file_, *gap_args = sys.argv[1:]
plan = json.load(open(plan_path))
release, ns = plan["release"], plan["ns"]
gaps = [a.split() for a in gap_args]
failed = False


def error(msg):
    global failed
    failed = True
    print(f"::error file={file_}::{release}: {msg}")


def read_docs(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip() not in ("", "null")]


def expand(rules):
    for rule in rules or []:
        for g in rule.get("apiGroups") or []:
            for r in rule.get("resources") or []:
                for v in rule.get("verbs") or []:
                    yield (g, r, v)


def unique(triples):
    out = []
    for t in triples:
        if t not in out:
            out.append(t)
    return out


def covers(granted_rules, t):
    return any(all(a in ("*", b) for a, b in zip(g, t)) for g in granted_rules)


def gap_covers(gap, t):
    _, group, resource, verbs = gap[:4]
    return group in ("*", t[0]) and resource in ("*", t[1]) and (verbs == "*" or t[2] in verbs.split(","))


docs = read_docs(plan["rendered"])
roles = {(d["kind"], d["metadata"]["name"]): d.get("rules")
         for d in docs if d.get("kind") in ("ClusterRole", "Role")}
bindings = [d for d in docs if d.get("kind") in ("ClusterRoleBinding", "RoleBinding")]


def granted(sa):
    out = []
    for b in bindings:
        subjects = b.get("subjects") or []
        if any(s.get("kind") == "ServiceAccount" and s.get("name") == sa and s.get("namespace", ns) == ns
               for s in subjects):
            ref = b["roleRef"]
            out += expand(roles.get((ref["kind"], ref["name"])))
    return unique(out)


def check_flags(sc):
    image = sc["name"]
    with open(sc["help_file"]) as f:
        text = f.read()
    if not re.search("usage", text, re.IGNORECASE):
        error(f"{image} printed no usage for --help or -h")
        return
    for arg in sc["args"]:
        if not arg.startswith("-"):
            continue
        flag = arg.lstrip("-").split("=", 1)[0]
        if not flag or not re.search(rf"(^|\s)--?{re.escape(flag)}(\s|=|$)", text, re.MULTILINE):
            error(f"{image} has no flag --{flag}")


def check_rbac(sc):
    image = sc["name"]
    required = unique(t for d in read_docs(sc["rbac_file"])
                      if d.get("kind") in ("ClusterRole", "Role")
                      for t in expand(d.get("rules")))
    have = granted(sc["sa"])
    applicable = [g for g in gaps if g[0] == image and (len(g) == 4 or g[4] in sc["args"])]
    used = {}
    for t in required:
        if covers(have, t):
            continue
        hit = next((i for i, g in enumerate(applicable) if gap_covers(g, t)), None)
        if hit is None:
            error(f"{image} needs {t[2]} {t[0] or 'core'}/{t[1]}, which the chart does not grant")
        else:
            used.setdefault(hit, []).append(t)
    for triples in used.values():
        by_resource = {}
        for g, r, v in triples:
            by_resource.setdefault(f"{g or 'core'}/{r}", []).append(v)
        listing = "; ".join(f"{k} {','.join(vs)}" for k, vs in by_resource.items())
        print(f"accepted: {release}: {image} {listing}")


for sc in plan["sidecars"]:
    check_flags(sc)
    # Node sidecars need no RBAC. A missing manifest was already reported by the fetch step.
    if sc["scope"] == "controller" and sc["rbac_file"] and os.path.exists(sc["rbac_file"]):
        check_rbac(sc)
sys.exit(1 if failed else 0)
PY
done

# Warns when a sidecar tag change flips a feature gate's default upstream.
fetch_gates() { # $1 = upstream repo, $2 = tag, $3 = output file
  local code
  code="$(curl -sSL --retry 5 --retry-all-errors -o "$3" -w '%{http_code}' \
    "https://raw.githubusercontent.com/kubernetes-csi/$1/$2/pkg/features/features.go" || true)"
  [ "$code" = 200 ] && return 0
  rm -f "$3"
  if [ "$code" = 404 ]; then
    echo "note: $1 $2 has no pkg/features/features.go; feature-gate diff skipped"
  else
    echo "::warning file=$file::could not fetch $1 $2 features.go (HTTP $code); feature-gate diff skipped"
  fi
  return 1
}

if [ -n "$base_sha" ] && git show "$base_sha:$file" > "$work/base.yaml" 2>/dev/null; then
  yq -o=json -I=0 '.' "$work/base.yaml" > "$work/base.jsonl"
  yq -o=json -I=0 '.' "$file" > "$work/head.jsonl"
  python3 - "$work/base.jsonl" "$work/head.jsonl" <<'PY' | sort -u > "$work/pairs.tsv"
import json, sys

# Image name -> (upstream repo, values path of its image block).
SIDECARS = {
    "csi-attacher": ("external-attacher", "controller.externalAttacher"),
    "csi-provisioner": ("external-provisioner", "controller.externalProvisioner"),
    "csi-resizer": ("external-resizer", "controller.externalResizer"),
    "csi-snapshotter": ("external-snapshotter", "controller.externalSnapshotter"),
    "csi-node-driver-registrar": ("node-driver-registrar", "node.driverRegistrar"),
}


def helm_releases(path):
    out = {}
    with open(path) as f:
        for line in f:
            if line.strip() in ("", "null"):
                continue
            d = json.loads(line)
            if d.get("kind") == "HelmRelease":
                out[d["metadata"]["name"]] = (d.get("spec") or {}).get("values") or {}
    return out


def tag_at(values, path):
    block = values
    for key in path.split(".") + ["image"]:
        block = (block or {}).get(key)
    return ((block or {}).get("tag") or "").split("@")[0]


base, head = helm_releases(sys.argv[1]), helm_releases(sys.argv[2])
for name, values in head.items():
    if name not in base:
        continue
    for image, (repo, path) in SIDECARS.items():
        old, new = tag_at(base[name], path), tag_at(values, path)
        if old and new and old != new:
            print(f"{image}\t{repo}\t{old}\t{new}")
PY

  : > "$work/gates.tsv"
  while IFS=$'\t' read -r image repo old new; do
    if fetch_gates "$repo" "$old" "$work/features/$repo-$old.go" &&
      fetch_gates "$repo" "$new" "$work/features/$repo-$new.go"; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$image" "$old" "$new" \
        "$work/features/$repo-$old.go" "$work/features/$repo-$new.go" >> "$work/gates.tsv"
    fi
  done < "$work/pairs.tsv"

  python3 - "$file" "$work/gates.tsv" <<'PY'
import re, sys

file_, rows = sys.argv[1], sys.argv[2]
CONST = re.compile(r'^\s*(\w+)\s+featuregate\.Feature\s*=\s*"([^"]+)"')
GATE = re.compile(r"^\s*(\w+):\s*\{")
DEFAULT = re.compile(r"Default:\s*(true|false)")


def gates(path):
    """Gate name -> default, from the defaults map in features.go. The last Default before the next gate key wins."""
    names, out, cur = {}, {}, None
    with open(path) as f:
        for line in f:
            m = CONST.match(line)
            if m:
                names[m.group(1)] = m.group(2)
            m = GATE.match(line)
            if m:
                cur = m.group(1)
                out[cur] = None
            elif line.startswith("}"):
                cur = None
            if cur is not None:
                for d in DEFAULT.findall(line):
                    out[cur] = d == "true"
    return {names.get(k, k): v for k, v in out.items() if v is not None}


with open(rows) as f:
    for line in f:
        image, old, new, old_path, new_path = line.rstrip("\n").split("\t")
        prefix = f"::warning file={file_}::{image} {old}→{new}:"
        o, n = gates(old_path), gates(new_path)
        if not o or not n:
            print(f"note: {image} {old}→{new}: no feature gates parsed; skipped")
            continue
        for k, v in n.items():
            if k not in o:
                print(f"{prefix} {k} added (default {str(v).lower()})")
            elif o[k] != v:
                print(f"{prefix} {k} default {str(o[k]).lower()}→{str(v).lower()}")
        for k, v in o.items():
            if k not in n:
                print(f"{prefix} {k} removed (was default {str(v).lower()})")
PY
fi

if [ "$status" -ne 0 ]; then
  exit 1
fi
echo "OK: democratic-csi sidecars match chart $(printf '%s\n' "${versions[@]}" | sort -u | paste -sd, -) flags and RBAC."
