#!/usr/bin/env bash
# Run a command and re-run it when, and only when, its output shows an HTTP 429.
#
#   retry-on-rate-limit.sh LOGFILE -- COMMAND [ARG...]
#
# Every attempt streams to stdout. LOGFILE is rewritten per attempt, so once the
# script returns it holds the final attempt's output alone and a caller that
# greps it (the values-drift gate in validate.yaml) sees one coherent run. The
# exit status is the final attempt's. A failure that is not a 429 is returned at
# once, so a genuine validation error still fails on the first try.
#
# Tunables (env): RETRY_ATTEMPTS is the total number of tries (default 6);
# RETRY_BASE_DELAY is the wait in seconds before the second try (default 15) and
# grows linearly, so the n-th wait is n * base: 15+30+45+60+75 = 225s overall.
#
# Why this exists: ghcr.io answers OCI pulls with
#   429 toomanyrequests: retry-after: 458.359µs, allowed: 44000/minute
# and flate only retries timeouts and connection resets, not HTTP 429. On this
# repo every such 429 was on ghcr.io/immich-app/immich-charts, inside the first
# ~3 minutes after the top of the hour, while the renovatebot and spegel-org
# charts pulled from the same runner at the same moment went through. That is a
# limit on the package owner's side, not a per-client one, so it only clears by
# waiting. A re-run is cheap: flate commits each artifact to its cache atomically
# and only the pull that failed is repeated.
set -uo pipefail

usage() {
  echo "usage: ${0##*/} LOGFILE -- COMMAND [ARG...]" >&2
  exit 2
}

[ "$#" -ge 3 ] && [ "$2" = "--" ] || usage
log="$1"
shift 2

attempts="${RETRY_ATTEMPTS:-6}"
base_delay="${RETRY_BASE_DELAY:-15}"

# What a registry or chart host says when it is throttling us: the OCI
# distribution error code, the HTTP reason phrase (helm's HTTP getter reports
# `429 Too Many Requests`), and oras-go's `response status code 429`.
rate_limited='toomanyrequests|too many requests|status code 429'

for ((attempt = 1; ; attempt++)); do
  "$@" 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"

  [ "$status" -eq 0 ] && exit 0
  grep -Eiq "$rate_limited" "$log" || exit "$status"

  if [ "$attempt" -ge "$attempts" ]; then
    echo "::error::still rate limited (HTTP 429) after $attempts attempts"
    exit "$status"
  fi

  # Jitter of up to 20% keeps concurrent jobs, which all start together when
  # Renovate opens its PRs, from retrying in lockstep.
  delay=$((base_delay * attempt))
  delay=$((delay + RANDOM % (delay / 5 + 1)))
  echo "::warning::rate limited (HTTP 429); retrying in ${delay}s (attempt $((attempt + 1)) of $attempts)"
  sleep "$delay"
done
