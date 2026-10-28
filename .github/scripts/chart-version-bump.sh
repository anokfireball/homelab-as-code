#!/usr/bin/env bash
# Fails when a chart under charts/ changes without a version bump in its Chart.yaml.
# Flux's default ChartVersion strategy produces no new chart artifact from a
# GitRepository unless that version changes
# (https://fluxcd.io/flux/components/source/helmcharts/), so the edit would never deploy.
#
#   chart-version-bump.sh BASE_SHA
#
# An empty BASE_SHA (merge_group, workflow_dispatch) is a no-op, as in image-refs.sh.
set -uo pipefail

BASE_SHA="${1?base sha required}"
[ -n "$BASE_SHA" ] || exit 0

status=0
while IFS= read -r chart; do
  file="charts/$chart/Chart.yaml"
  # A deleted chart has no Chart.yaml; its consumers fail in flate test instead.
  [ -f "$file" ] || continue
  new=$(yq '.version // ""' "$file")
  if ! [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "::error file=$file::version '$new' is not MAJOR.MINOR.PATCH"
    status=1
    continue
  fi
  old=$(git show "$BASE_SHA:$file" 2>/dev/null | yq '.version // ""' 2>/dev/null || true)
  # A new chart has no base version to compare against.
  [ -n "$old" ] || continue
  top=$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n1)
  if [ "$new" = "$old" ] || [ "$top" != "$new" ]; then
    echo "::error file=$file::charts/$chart changed without a version bump (version $new, base $old)"
    status=1
  fi
done < <(git diff --name-only "$BASE_SHA"...HEAD -- 'charts/**' |
         awk -F/ 'NF > 2 { print $2 }' | sort -u)
[ "$status" -ne 0 ] || echo "OK: every changed chart bumps its Chart.yaml version."
exit "$status"
