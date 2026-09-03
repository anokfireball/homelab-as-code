#!/usr/bin/env bash
# Report container-contract changes for image references this PR introduces.
# Advisory only: never exits non-zero.
set -uo pipefail

# Empty (not missing) base sha: no PR delta to report on. See image-refs.sh.
BASE_SHA="${1?base sha required}"
OUT="${2:?output file required}"
: >"$OUT"
[ -n "$BASE_SHA" ] || exit 0

# Fields that break a Deployment when they change, projected to YAML for dyff.
project() { # $1 = ref -> stdout YAML, non-zero if the config is unavailable
  cfg=$(crane config "$1" 2>/dev/null) || return 1
  [ -n "$cfg" ] || return 1
  printf '%s' "$cfg" | jq '{
    entrypoint: (.config.Entrypoint // []),
    cmd:        (.config.Cmd // []),
    user:       (.config.User // ""),
    workingDir: (.config.WorkingDir // ""),
    exposedPorts: ((.config.ExposedPorts // {}) | keys),
    volumes:      ((.config.Volumes // {}) | keys),
    env:          (.config.Env // [])
  }' | yq -P '.'
}

new_refs=$(.github/scripts/image-refs.sh "$BASE_SHA")
[ -n "$new_refs" ] || exit 0

# Old refs, so a new ref can be paired with the previous ref for the same repo.
old_refs=$(git diff --name-only "$BASE_SHA"...HEAD -- 'flux/**/*.yaml' 2>/dev/null \
  | while read -r f; do git show "$BASE_SHA:$f" 2>/dev/null; echo "---"; done \
  | yq -N '
      [ .. | select(kind == "map" and has("repository") and has("tag"))
            | .repository + ":" + .tag ]
      + [ .. | select(kind == "map") | to_entries | .[]
            | select(.key | test("[Ii]mage$")) | .value | select(kind == "scalar") ]
      | .[]
    ' 2>/dev/null | grep -E '^[^[:space:]]+:[^[:space:]]+$' | sort -u)

repo_of() { r="${1%@sha256:*}"; b="${r##*/}"; p="${r%"$b"}"; printf '%s%s' "$p" "${b%:*}"; }

while read -r ref; do
  [ -n "$ref" ] || continue
  repo=$(repo_of "$ref")
  old=$(printf '%s\n' "$old_refs" | while read -r o; do
          [ -n "$o" ] && [ "$(repo_of "$o")" = "$repo" ] && echo "$o"; done | head -1)
  [ -n "$old" ] || continue
  [ "$old" != "$ref" ] || continue

  project "$old" >/tmp/icd-old.yaml || { echo "- \`$repo\`: config for the previous image unavailable; skipped" >>"$OUT"; continue; }
  project "$ref" >/tmp/icd-new.yaml || { echo "- \`$repo\`: config for the new image unavailable; skipped" >>"$OUT"; continue; }

  d=$(dyff between --omit-header /tmp/icd-old.yaml /tmp/icd-new.yaml 2>/dev/null)
  if [ -n "$d" ]; then
    { echo "<details><summary><code>$repo</code> container contract changed</summary>"; echo;
      echo '```'; printf '%s\n' "$d" | head -80; echo '```'; echo '</details>'; echo; } >>"$OUT"
  fi
done <<<"$new_refs"
exit 0
