// Moves the Envoy proxy image override on EnvoyProxy eg-shared onto the Envoy release that the
// gateway-helm chart in the HelmRelease expects.
//
// Renovate runs this as a post-upgrade task of a gateway-helm minor or major update, after the new
// chart version is in the HelmRelease. From the repository root:
//   node .github/scripts/renovate-envoy-override.mjs
// Each Envoy Gateway release is built against one Envoy minor, named by the DefaultEnvoyProxyImage
// constant in api/v1alpha1/shared_types.go at tag v<chart version> (the same lookup as
// envoy-proxy-compat.sh, which fails a PR that leaves the override on another minor). When the
// override is on another minor, or on an older patch of the same minor, it is replaced by that
// constant, tag and digest. An override on the same minor at an equal or newer patch is left alone,
// so this never downgrades the proxy and Renovate keeps owning the patch updates. A HelmRelease
// without an override is left alone. Any fetch or parse error exits 1 without writing.
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../', import.meta.url));
const CHART_FILE = 'flux/system/app-controllers/envoy-gateway.yaml';
const OVERRIDE_FILE = 'flux/system/app-configs/envoy-gateway.yaml';

const OVERRIDE = /image: docker\.io\/envoyproxy\/envoy:distroless-v(\d+)\.(\d+)\.(\d+)(?:@sha256:[a-f0-9]+)?/g;
const DEFAULT_IMAGE = /DefaultEnvoyProxyImage\s*=\s*"(docker\.io\/envoyproxy\/envoy:distroless-v(\d+)\.(\d+)\.(\d+)@sha256:[a-f0-9]{64})"/;

async function main() {
  const chartBody = readFileSync(root + CHART_FILE, 'utf8');
  const chartVersion = /chart: gateway-helm\b[\s\S]*?\bversion:\s*(\S+)/.exec(chartBody)?.[1];
  if (!chartVersion) fail(`could not find the gateway-helm chart version in ${CHART_FILE}`);

  const overrideBody = readFileSync(root + OVERRIDE_FILE, 'utf8');
  const overrides = [...overrideBody.matchAll(OVERRIDE)];
  if (overrides.length === 0) {
    console.log(`No Envoy image override in ${OVERRIDE_FILE}; the proxy follows gateway-helm ${chartVersion}.`);
    return;
  }
  if (overrides.length > 1) fail(`expected one Envoy image override in ${OVERRIDE_FILE}, found ${overrides.length}`);

  const url = `https://raw.githubusercontent.com/envoyproxy/gateway/v${chartVersion}/api/v1alpha1/shared_types.go`;
  const response = await fetch(url, { signal: AbortSignal.timeout(60_000) });
  if (!response.ok) fail(`GET ${url}: HTTP ${response.status}`);
  const found = DEFAULT_IMAGE.exec(await response.text());
  if (!found) fail(`could not read DefaultEnvoyProxyImage from ${url}`);
  const [, defaultImage, ...defaultVersion] = found;
  const [dMajor, dMinor, dPatch] = defaultVersion.map(Number);

  const [match, ...overrideVersion] = overrides[0];
  const [oMajor, oMinor, oPatch] = overrideVersion.map(Number);
  console.log(`gateway-helm ${chartVersion} ships Envoy ${dMajor}.${dMinor}.${dPatch}; override is Envoy ${oMajor}.${oMinor}.${oPatch}.`);

  if (oMajor === dMajor && oMinor === dMinor && oPatch >= dPatch) {
    console.log('Override is on the chart minor and not older than the chart default; leaving it.');
    return;
  }

  writeFileSync(root + OVERRIDE_FILE, overrideBody.replace(match, `image: ${defaultImage}`));
  console.log(`Override set to ${defaultImage}.`);
}

function fail(message) {
  console.error(`renovate-envoy-override: ${message}`);
  process.exit(1);
}

main().catch((error) => fail(error.message));
