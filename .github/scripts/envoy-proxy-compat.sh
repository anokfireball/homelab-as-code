#!/usr/bin/env bash
# Keep the Envoy Proxy image override on EnvoyProxy eg-shared in step with the
# gateway-helm chart.
#
#   envoy-proxy-compat.sh
#
# Each Envoy Gateway release is built and tested against one Envoy minor. The
# chart leaves `global.images.envoyProxy.image` empty, so the version that
# release actually runs is the controller's `DefaultEnvoyProxyImage` constant in
# api/v1alpha1/shared_types.go at tag v<chart version> (chart and controller
# versions are the same). The override pins the image explicitly to pick up
# Envoy patch releases (CVE fixes) before Envoy Gateway ships them, and Renovate
# only bumps it within its current minor. Nothing else ties that minor to the
# chart, so a gateway-helm minor bump would otherwise leave the new controller
# driving the old proxy.
#
# Fails when the override's minor differs from the chart default's, or when the
# override is an older patch than the chart default (it would downgrade the
# proxy). Passes when there is no override. An override equal to the chart
# default is redundant; that is a warning, not a failure.
set -euo pipefail

chart_file=flux/system/app-controllers/envoy-gateway.yaml
override_file=flux/system/app-configs/envoy-gateway.yaml

chart_version="$(awk '/chart: gateway-helm/{f=1; next} f && /version:/{print $2; exit}' "$chart_file")"
if [ -z "$chart_version" ]; then
  echo "::error file=$chart_file::could not find the gateway-helm chart version"
  exit 1
fi

override="$(grep -oE 'image: docker\.io/envoyproxy/envoy:distroless-v[0-9]+\.[0-9]+\.[0-9]+' "$override_file" | sed 's/.*:distroless-v//' || true)"
if [ -z "$override" ]; then
  echo "No Envoy image override on EnvoyProxy eg-shared; the proxy follows gateway-helm $chart_version."
  exit 0
fi

url="https://raw.githubusercontent.com/envoyproxy/gateway/v${chart_version}/api/v1alpha1/shared_types.go"
default_image="$(curl -fsSL --retry 5 --retry-all-errors "$url" \
  | sed -nE 's/.*DefaultEnvoyProxyImage *= *"([^"]+)".*/\1/p' | head -n1)"
default="$(sed -nE 's/.*:distroless-v([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$default_image")"
if [ -z "$default" ]; then
  echo "::error::could not read DefaultEnvoyProxyImage from $url"
  exit 1
fi

IFS=. read -r o_major o_minor o_patch <<<"$override"
IFS=. read -r d_major d_minor d_patch <<<"$default"

echo "gateway-helm $chart_version ships Envoy $default; override is Envoy $override."

if [ "$o_major.$o_minor" != "$d_major.$d_minor" ]; then
  echo "::error file=$override_file::Envoy override $override is not on the Envoy minor gateway-helm $chart_version ships ($d_major.$d_minor). In this PR, set the image to distroless-v$d_major.$d_minor.x (at least $default; chart default: $default_image), or delete the override to follow the chart."
  exit 1
fi

if [ "$o_patch" -lt "$d_patch" ]; then
  echo "::error file=$override_file::Envoy override $override is older than gateway-helm $chart_version's default $default and would downgrade the proxy. Bump it to at least $default, or delete the override."
  exit 1
fi

if [ "$o_patch" -eq "$d_patch" ]; then
  echo "::warning file=$override_file::Envoy override $override equals gateway-helm $chart_version's default; the override can be deleted."
fi

echo "OK: override $override is on gateway-helm $chart_version's Envoy minor $d_major.$d_minor."
