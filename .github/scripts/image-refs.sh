#!/usr/bin/env bash
# Print image references under flux/** for the files this PR changes:
#   (default) refs the PR introduces -- present at HEAD, absent at the base
#   --old     refs those same files carried at the base commit, so a consumer
#             can pair an introduced ref with the one it replaces (see
#             .github/scripts/image-config-diff.sh)
set -uo pipefail

MODE=new
if [ "${1-}" = "--old" ]; then
  MODE=old
  shift
fi

# `${1?...}` without the colon: a missing argument is a caller bug and must fail
# loudly, but an *empty* one is legitimate. `github.event.pull_request.base.sha`
# is empty on `merge_group` and `workflow_dispatch` runs, where there is no PR
# delta to inspect, so that case is a clean no-op.
BASE_SHA="${1?base sha required}"
[ -n "$BASE_SHA" ] || exit 0

# Every image ref in one YAML document stream on stdin.
#   - recursive (repository,tag) map pairs: covers both the flat
#     `image: {repository, tag}` shape and the nested
#     `controllers.*.containers.*.image` shape. A sibling `registry` is
#     prefixed when present: dropping it leaves a bare `owner/name`, which
#     every OCI client resolves against docker.io, so a ghcr.io-only image
#     looks like it does not exist.
#   - scalar values under any key ending in `Image` (e.g. `healthcheckImage`),
#     which Renovate also bumps
refs() {
  yq -N '
    [ .. | select(kind == "map" and has("repository") and has("tag"))
          | (((.registry // "") + "/" + .repository) | sub("^/", "")) + ":" + .tag ]
    + [ .. | select(kind == "map") | to_entries | .[]
          | select(.key | test("[Ii]mage$")) | .value | select(kind == "scalar") ]
    | .[]
  ' 2>/dev/null | grep -E '^[^[:space:]]+:[^[:space:]]+$' | sort -u
}

changed=$(git diff --name-only "$BASE_SHA"...HEAD -- 'flux/**/*.yaml' || true)
[ -n "$changed" ] || exit 0

for f in $changed; do
  old=$(git show "$BASE_SHA:$f" 2>/dev/null | refs)
  if [ "$MODE" = "old" ]; then
    printf '%s\n' "$old" | grep -v '^$'
    continue
  fi
  new=""
  [ -f "$f" ] && new=$(refs <"$f")
  # refs in new that are not in old
  comm -23 <(printf '%s\n' "$new" | grep -v '^$' | sort -u) \
           <(printf '%s\n' "$old" | grep -v '^$' | sort -u)
done | sort -u
exit 0
