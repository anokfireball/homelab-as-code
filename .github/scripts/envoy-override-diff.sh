#!/usr/bin/env bash
# Report a change of the Envoy proxy image override on EnvoyProxy eg-shared.
#
#   envoy-override-diff.sh <base sha> <output file>
#
# Writes a Markdown <details> block to the output file only when the override differs from the PR
# base, in the shape of chart-values-diff.sh: a summary line and a fenced diff of the `image:`
# line. Below the diff it states how the override relates to the Envoy image the pinned
# gateway-helm chart ships (the same lookup as envoy-proxy-compat.sh), so a reader sees whether
# the override moved with the chart. Advisory only: never exits non-zero.
set -uo pipefail

BASE_SHA="${1?base sha required}"
OUT="${2:?output file required}"
: >"$OUT"
# Empty (not missing) base sha: no PR delta to report on. See image-refs.sh.
[ -n "$BASE_SHA" ] || exit 0

chart_file=flux/system/app-controllers/envoy-gateway.yaml
override_file=flux/system/app-configs/envoy-gateway.yaml
pattern='image: docker\.io/envoyproxy/envoy:distroless-v[0-9]+\.[0-9]+\.[0-9]+(@sha256:[a-f0-9]+)?'

# The `image: ...` line in stdin, or nothing when there is no override.
override_line() { grep -oE "$pattern" | head -n1; }
# Bare X.Y.Z of the first `distroless-vX.Y.Z` in the argument.
version_of() { sed -nE 's/.*distroless-v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$1"; }

old=$(git show "$BASE_SHA:$override_file" 2>/dev/null | override_line)
new=$(override_line <"$override_file" 2>/dev/null)
[ "$old" != "$new" ] || exit 0

old_version=$(version_of "$old")
new_version=$(version_of "$new")

if [ -z "$old" ]; then
  summary="override added: $new_version"
elif [ -z "$new" ]; then
  summary="override removed; the proxy follows gateway-helm's default image"
else
  IFS=. read -r o_major o_minor o_patch <<<"$old_version"
  IFS=. read -r n_major n_minor n_patch <<<"$new_version"
  kind="digest refresh"
  if [ "$o_major.$o_minor" != "$n_major.$n_minor" ]; then
    kind="minor change"
  elif [ "$o_patch" != "$n_patch" ]; then
    kind="patch change"
  fi
  summary="<code>envoyproxy/envoy</code> $old_version -> $new_version ($kind)"
fi

relation=""
if [ -n "$new" ]; then
  chart_version=$(awk '/chart: gateway-helm/{f=1; next} f && /version:/{print $2; exit}' "$chart_file")
  if [ -n "$chart_version" ]; then
    url="https://raw.githubusercontent.com/envoyproxy/gateway/v${chart_version}/api/v1alpha1/shared_types.go"
    default_image=$(curl -fsSL --retry 3 --retry-all-errors "$url" 2>/dev/null \
      | sed -nE 's/.*DefaultEnvoyProxyImage *= *"docker\.io\/envoyproxy\/envoy:([^"]+)".*/\1/p' | head -n1)
    default_version=$(version_of "$default_image")
    if [ -n "$default_version" ]; then
      IFS=. read -r d_major d_minor d_patch <<<"$default_version"
      IFS=. read -r n_major n_minor n_patch <<<"$new_version"
      if [ "$n_major.$n_minor" != "$d_major.$d_minor" ]; then
        how="on another Envoy minor than that default"
      elif [ "$n_patch" -lt "$d_patch" ]; then
        how="an older patch than that default"
      elif [ "$n_patch" -eq "$d_patch" ]; then
        how="equal to that default"
      else
        how="a newer patch than that default"
      fi
      relation="gateway-helm \`$chart_version\` ships \`distroless-v$default_version\`; the override is $how."
    fi
  fi
fi

{
  echo "<details><summary><code>eg-shared</code>: $summary</summary>"
  echo
  echo '```diff'
  [ -z "$old" ] || echo "- $old"
  [ -z "$new" ] || echo "+ $new"
  echo '```'
  if [ -n "$relation" ]; then
    echo
    echo "$relation"
  fi
  echo
  echo '</details>'
  echo
} >"$OUT"
exit 0
