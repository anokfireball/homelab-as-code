#!/usr/bin/env bash
# Verify each image reference on stdin resolves and provides linux/amd64.
# The cluster is amd64-only (ansible/cluster/roles/k8s_cluster/tasks/tasks/repos.yaml
# pins `arch=amd64`; ansible/cluster/roles/k8s_flux/tasks/main.yaml fetches
# flux_..._linux_amd64.tar.gz), so a tag that drops amd64 breaks every node.
set -uo pipefail

fail=0
while read -r ref; do
  [ -n "$ref" ] || continue

  # Normalize `repo:tag@sha256:...` to `repo@sha256:...`: the digest is
  # authoritative, and passing both a tag and a digest relies on parser
  # behaviour we should not depend on. Only the last path element is
  # stripped, so a `host:port/repo` prefix survives.
  probe="$ref"
  if [ "${ref#*@sha256:}" != "$ref" ]; then
    digest="${ref##*@sha256:}"
    name="${ref%@sha256:*}"
    base="${name##*/}"
    prefix="${name%"$base"}"
    base="${base%:*}"
    probe="${prefix}${base}@sha256:${digest}"
  fi

  if ! man=$(crane manifest "$probe" 2>&1); then
    echo "::error::image reference does not resolve: $ref"
    printf '%s\n' "$man" | head -3
    fail=1
    continue
  fi

  # Multi-arch index -> require a linux/amd64 entry. Single manifest -> the
  # image config carries the architecture.
  if printf '%s' "$man" | jq -e 'has("manifests")' >/dev/null 2>&1; then
    if ! printf '%s' "$man" | jq -e '
      .manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")
    ' >/dev/null 2>&1; then
      echo "::error::no linux/amd64 in image index: $ref"
      printf '%s' "$man" | jq -r '.manifests[] | "  " + (.platform.os // "?") + "/" + (.platform.architecture // "?")'
      fail=1
    fi
  else
    arch=$(crane config "$probe" 2>/dev/null | jq -r '.architecture // ""')
    if [ "$arch" != "amd64" ]; then
      echo "::error::single-arch image is not amd64 ($arch): $ref"
      fail=1
    fi
  fi
  echo "checked $ref"
done
exit "$fail"
