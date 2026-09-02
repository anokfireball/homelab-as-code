#!/usr/bin/env bash
# Report Helm chart values-interface changes for HelmReleases whose chart
# version changed in this PR. Advisory only: never exits non-zero.
set -uo pipefail

BASE_SHA="${1:?base sha required}"
OUT="${2:?output file required}"
: >"$OUT"

repo_url() { # $1 = HelmRepository name -> "<url>\t<type>"
  yq -N 'select(.kind == "HelmRepository") | select(.metadata.name == "'"$1"'")
         | (.spec.url // "") + "\t" + (.spec.type // "default")' \
    flux/repositories/*.yaml 2>/dev/null | grep -v '^\s*$' | head -1
}

values_at() { # $1 = chart, $2 = version, $3 = url, $4 = type, $5 = outfile
  if [ "$4" = "oci" ]; then
    # helm v4 prints per-pull metadata ("Pulled:"/"Digest:") to stdout ahead
    # of the values; left in, those differ on every bump and drown the real
    # interface change. helm v3 does not emit them, so this is a no-op there.
    helm show values "${3%/}/$1" --version "$2" 2>/dev/null \
      | grep -vE '^(Pulled|Digest):' >"$5"
  else
    local alias="cvd-$(printf '%s' "$3" | md5sum | cut -c1-10)"
    helm repo add "$alias" "$3" >/dev/null 2>&1 || return 1
    helm repo update "$alias" >/dev/null 2>&1 || return 1
    helm show values "$alias/$1" --version "$2" >"$5" 2>/dev/null
  fi
}

changed=$(git diff --name-only "$BASE_SHA"...HEAD -- 'flux/**/*.yaml' || true)
[ -n "$changed" ] || exit 0

for f in $changed; do
  [ -f "$f" ] || continue
  while IFS=$'\t' read -r name chart version src; do
    [ -n "${chart:-}" ] && [ -n "${version:-}" ] || continue
    old=$(git show "$BASE_SHA:$f" 2>/dev/null \
          | yq -N 'select(.kind == "HelmRelease") | select(.metadata.name == "'"$name"'")
                   | .spec.chart.spec.version // ""' 2>/dev/null | head -1)
    [ -n "$old" ] && [ "$old" != "$version" ] || continue

    IFS=$'\t' read -r url type <<<"$(repo_url "$src")"
    [ -n "${url:-}" ] || { echo "- \`$name\`: $old -> $version (source \`$src\` not resolved; skipped)" >>"$OUT"; continue; }

    values_at "$chart" "$old" "$url" "$type" /tmp/cvd-old.yaml || { echo "- \`$name\`: $old -> $version (values for $old unavailable; skipped)" >>"$OUT"; continue; }
    values_at "$chart" "$version" "$url" "$type" /tmp/cvd-new.yaml || { echo "- \`$name\`: $old -> $version (values for $version unavailable; skipped)" >>"$OUT"; continue; }

    d=$(dyff between --omit-header /tmp/cvd-old.yaml /tmp/cvd-new.yaml 2>/dev/null)
    if [ -n "$d" ]; then
      { echo "<details><summary><code>$name</code>: <code>$chart</code> $old -> $version</summary>"; echo;
        echo '```'; printf '%s\n' "$d" | head -120; echo '```'; echo '</details>'; echo; } >>"$OUT"
    else
      echo "- \`$name\`: \`$chart\` $old -> $version — no values-interface change" >>"$OUT"
    fi
  done < <(yq -N 'select(.kind == "HelmRelease")
                 | (.metadata.name // "") + "\t" + (.spec.chart.spec.chart // "")
                   + "\t" + (.spec.chart.spec.version // "")
                   + "\t" + (.spec.chart.spec.sourceRef.name // "")' "$f" 2>/dev/null)
done
exit 0
