// Keeps the chart-owned image pins of a HelmRelease at the chart's own defaults.
//
// Renovate runs this as a post-upgrade task of a chart update, after the new chart version is in
// the HelmRelease. From the repository root:
//   node .github/scripts/renovate-chart-images.mjs <chart>
// It reads the chart version and repository from the HelmRelease and flux/repositories/, downloads
// the chart from the repository index (the tarball must match the index digest), takes each image
// tag from the chart (a values.yaml path, or appVersion), and resolves each tag to the digest the
// registry reports for its manifest list, which is the digest Renovate pins. It then rewrites every
// pin: the `tag:` value of a values pin, and every full reference to the image. The file is written
// only when a pin changes. Any fetch, parse or pin error exits 1 without writing.
// Uses the `yaml` package: this checkout's node_modules or NODE_PATH, else the Renovate image's copy.
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';

const root = fileURLToPath(new URL('../../', import.meta.url));

const require = createRequire(import.meta.url);
const RENOVATE_ROOT = '/usr/local/renovate';

// Loads the yaml package from this checkout's module resolution (node_modules, NODE_PATH), then from
// the working directory and the Renovate image's install. Exits 1 when neither has it.
function loadYaml() {
  const lookups = [
    () => require.resolve('yaml'),
    () => require.resolve('yaml', { paths: [process.cwd(), root, RENOVATE_ROOT] }),
  ];
  for (const lookup of lookups) {
    try {
      return require(lookup());
    } catch (error) {
      if (error.code !== 'MODULE_NOT_FOUND') throw error;
    }
  }
  console.error(`renovate-chart-images: cannot resolve the yaml package from the script, ${process.cwd()}, or ${RENOVATE_ROOT}; install it or set NODE_PATH`);
  process.exit(1);
}

const YAML = loadYaml();

// `name` is the image as Renovate names it (the annotation depName). `values` is the HelmRelease
// `spec.values` object holding the pin; images that appear only as full references have none.
// `tag` is where the chart's default tag comes from: a path in its values.yaml, or appVersion.
// `annotated` pins carry a `# renovate: datasource=docker depName=<name>` line above their `tag:`.
const CHARTS = {
  longhorn: {
    file: 'flux/system/app-controllers/longhorn.yaml',
    images: [
      { name: 'docker.io/longhornio/longhorn-ui', values: 'image.longhorn.ui', tag: { values: 'image.longhorn.ui.tag' }, annotated: true },
      { name: 'docker.io/longhornio/csi-attacher', values: 'image.csi.attacher', tag: { values: 'image.csi.attacher.tag' }, annotated: true },
      { name: 'docker.io/longhornio/csi-provisioner', values: 'image.csi.provisioner', tag: { values: 'image.csi.provisioner.tag' }, annotated: true },
      { name: 'docker.io/longhornio/csi-resizer', values: 'image.csi.resizer', tag: { values: 'image.csi.resizer.tag' }, annotated: true },
      { name: 'docker.io/longhornio/csi-snapshotter', values: 'image.csi.snapshotter', tag: { values: 'image.csi.snapshotter.tag' }, annotated: true },
      // The HelmRelease sets no manager values; post-renderer patches name the manager in full.
      { name: 'longhornio/longhorn-manager', tag: { values: 'image.longhorn.manager.tag' } },
    ],
  },
  pihole: {
    file: 'flux/apps/pihole.yaml',
    // The chart renders `image.tag | default .Chart.AppVersion`, and the HelmRelease sets that tag.
    images: [{ name: 'pihole/pihole', values: 'image', tag: { appVersion: true } }],
  },
};

const TAG_LINE = /^(\s*tag:\s*)(["']?)(.*?)\2(\s*(?:#.*)?)$/;
const MANIFEST_ACCEPT = [
  'application/vnd.oci.image.index.v1+json',
  'application/vnd.docker.distribution.manifest.list.v2+json',
  'application/vnd.oci.image.manifest.v1+json',
  'application/vnd.docker.distribution.manifest.v2+json',
].join(', ');

async function main() {
  const [chart, ...extra] = process.argv.slice(2);
  const config = CHARTS[chart];
  if (!config || extra.length > 0) {
    throw new Error(`usage: node .github/scripts/renovate-chart-images.mjs <${Object.keys(CHARTS).join('|')}>`);
  }

  const text = readFileSync(join(root, config.file), 'utf8');
  const release = onlyOne(
    parseDocuments(text, config.file).filter((doc) => doc?.kind === 'HelmRelease' && doc.spec?.chart?.spec?.chart === chart),
    `HelmRelease of chart ${chart} in ${config.file}`,
  );
  const { version, sourceRef } = release.spec.chart.spec;
  if (typeof version !== 'string') throw new Error(`${config.file}: spec.chart.spec.version must be a string`);
  const { chartYaml, valuesYaml } = await fetchChart(await helmRepositoryUrl(sourceRef), chart, version);

  let body = text;
  const pins = [];
  for (const image of config.images) {
    const tag = image.tag.appVersion ? chartYaml.appVersion : getPath(valuesYaml, image.tag.values);
    if (typeof tag !== 'string' || tag === '') throw new Error(`${chart} ${version}: the chart sets no tag for ${image.name}`);
    const pin = `${tag}@${await imageDigest(image.name, tag)}`;
    if (image.values) body = replaceValuePin(body, release, image, pin, config.file);
    body = replaceReferences(body, image, pin, config.file);
    pins.push(`${image.name}:${pin}`);
  }

  if (body !== text) writeFileSync(join(root, config.file), body);
  console.log(`${config.file} (${chart} ${version}): ${body === text ? 'already in sync' : 'pins updated'}`);
  for (const pin of pins) console.log(`  ${pin}`);
}

// Rewrites the `tag:` line of a values pin. The old pin must be unique in the file, and an
// annotated pin must sit directly under its Renovate annotation.
function replaceValuePin(body, release, image, pin, file) {
  const values = getPath(release.spec.values, image.values);
  if (!values || typeof values !== 'object') throw new Error(`${file}: no spec.values.${image.values} for ${image.name}`);
  if (normalizeRef(`${values.registry ? `${values.registry}/` : ''}${values.repository}`) !== normalizeRef(image.name)) {
    throw new Error(`${file}: spec.values.${image.values} is not ${image.name}`);
  }
  const old = values.tag;
  if (typeof old !== 'string' || !/^[^@\s]+@sha256:[0-9a-f]{64}$/.test(old)) {
    throw new Error(`${file}: the ${image.name} tag is not pinned by digest`);
  }

  const lines = body.split('\n');
  const hits = lines.flatMap((line, i) => (TAG_LINE.exec(line)?.[3] === old ? [i] : []));
  if (hits.length !== 1) throw new Error(`${file}: expected one tag line pinning ${old}, found ${hits.length}`);
  const [i] = hits;
  if (image.annotated && lines[i - 1]?.trim() !== `# renovate: datasource=docker depName=${image.name}`) {
    throw new Error(`${file}:${i + 1}: the ${image.name} tag has no renovate annotation directly above it`);
  }
  const [, before, quote, , after] = TAG_LINE.exec(lines[i]);
  lines[i] = `${before}${quote}${pin}${quote}${after}`;
  return lines.join('\n');
}

// Rewrites every full reference to the image (`[docker.io/]<name>:<tag>@sha256:<digest>`). A
// reference without a digest is an error, and an image with no values pin must have at least one.
function replaceReferences(body, image, pin, file) {
  const repo = image.name.replace(/^docker\.io\//, '');
  const name = escapeRegExp(repo);
  const pinned = new RegExp(`(?<![\\w./-])((?:docker\\.io/)?)${name}:[^\\s"'@]+@sha256:[0-9a-f]{64}`, 'g');
  const mention = new RegExp(`(?<![\\w./-])(?:docker\\.io/)?${name}:`, 'g');
  const mentions = body.match(mention)?.length ?? 0;
  let count = 0;
  const out = body.replace(pinned, (_, prefix) => {
    count++;
    return `${prefix}${repo}:${pin}`;
  });
  if (mentions !== count) throw new Error(`${file}: ${mentions - count} reference(s) to ${repo} carry no digest`);
  if (!image.values && count === 0) throw new Error(`${file}: no pinned reference to ${repo}`);
  return out;
}

async function helmRepositoryUrl(sourceRef) {
  if (sourceRef?.kind !== 'HelmRepository') throw new Error(`the chart source must be a HelmRepository, found ${sourceRef?.kind}`);
  const dir = join(root, 'flux/repositories');
  const repositories = readdirSync(dir)
    .filter((file) => file.endsWith('.yaml'))
    .sort()
    .flatMap((file) =>
      parseDocuments(readFileSync(join(dir, file), 'utf8'), `flux/repositories/${file}`).filter(
        (doc) =>
          doc?.kind === 'HelmRepository' &&
          doc.metadata?.name === sourceRef.name &&
          (!sourceRef.namespace || doc.metadata?.namespace === sourceRef.namespace),
      ),
    );
  const repo = onlyOne(repositories, `HelmRepository ${sourceRef.name}`);
  if (repo.spec?.type && repo.spec.type !== 'default') throw new Error(`HelmRepository ${sourceRef.name}: type ${repo.spec.type} is not supported`);
  if (typeof repo.spec?.url !== 'string') throw new Error(`HelmRepository ${sourceRef.name} has no spec.url`);
  return repo.spec.url;
}

// Reads Chart.yaml and values.yaml from the chart tarball that the repository index lists for
// `version`, after checking the tarball against the index digest.
async function fetchChart(repoUrl, chart, version) {
  const indexUrl = new URL('index.yaml', repoUrl.endsWith('/') ? repoUrl : `${repoUrl}/`);
  const [index] = parseDocuments(await getText(indexUrl), indexUrl.href);
  const listed = Array.isArray(index?.entries?.[chart]) ? index.entries[chart].filter((entry) => entry.version === version) : [];
  const entry = onlyOne(listed, `${chart} ${version} entry in ${indexUrl.href}`);
  if (typeof entry.urls?.[0] !== 'string' || typeof entry.digest !== 'string') {
    throw new Error(`${chart} ${version}: the index entry has no url or digest`);
  }
  const archiveUrl = new URL(entry.urls[0], indexUrl);
  const archive = await getBytes(archiveUrl);
  const digest = createHash('sha256').update(archive).digest('hex');
  if (digest !== entry.digest) throw new Error(`${archiveUrl.href}: sha256 ${digest} differs from the index digest ${entry.digest}`);

  const files = readTar(gunzipSync(archive));
  const chartYaml = chartDocument(files, `${chart}/Chart.yaml`);
  const valuesYaml = chartDocument(files, `${chart}/values.yaml`);
  if (chartYaml.name !== chart || chartYaml.version !== version) {
    throw new Error(`${archiveUrl.href}: Chart.yaml names ${chartYaml.name} ${chartYaml.version}, expected ${chart} ${version}`);
  }
  return { chartYaml, valuesYaml };
}

function chartDocument(files, path) {
  const data = files.get(path);
  if (!data) throw new Error(`the chart archive has no ${path}`);
  const [doc] = parseDocuments(data.toString('utf8'), path);
  if (!doc || typeof doc !== 'object') throw new Error(`${path} is not a mapping`);
  return doc;
}

// Manifest digest of `name:tag` as the registry reports it for the manifest list, with the
// bearer-token challenge handled as the registry names it.
async function imageDigest(name, tag) {
  const { host, repo } = registryRepo(name);
  const url = `https://${host}/v2/${repo}/manifests/${tag}`;
  const head = (headers = {}) => request(url, { method: 'HEAD', headers: { Accept: MANIFEST_ACCEPT, ...headers }, timeout: 30_000 });

  let response = await head();
  if (response.status === 401) {
    const challenge = response.headers.get('www-authenticate') ?? '';
    const params = Object.fromEntries([...challenge.matchAll(/(\w+)="([^"]*)"/g)].map(([, key, value]) => [key, value]));
    if (!/^bearer\s/i.test(challenge) || !params.realm) throw new Error(`${name}:${tag}: unsupported registry challenge "${challenge}"`);
    const tokenUrl = new URL(params.realm);
    if (params.service) tokenUrl.searchParams.set('service', params.service);
    tokenUrl.searchParams.set('scope', params.scope ?? `repository:${repo}:pull`);
    const tokenResponse = await request(tokenUrl, { timeout: 30_000 });
    if (!tokenResponse.ok) throw new Error(`${name}:${tag}: token request failed with HTTP ${tokenResponse.status}`);
    const { token, access_token: accessToken } = await tokenResponse.json();
    const bearer = token ?? accessToken;
    if (typeof bearer !== 'string') throw new Error(`${name}:${tag}: token response has no token`);
    response = await head({ Authorization: `Bearer ${bearer}` });
  }
  if (!response.ok) throw new Error(`${name}:${tag}: manifest request failed with HTTP ${response.status}`);
  const digest = response.headers.get('docker-content-digest');
  if (!/^sha256:[0-9a-f]{64}$/.test(digest ?? '')) throw new Error(`${name}:${tag}: the registry returned no digest`);
  return digest;
}

// Docker Hub is served from registry-1.docker.io, and its single-name repositories live under library/.
function registryRepo(name) {
  const slash = name.indexOf('/');
  const first = slash > 0 ? name.slice(0, slash) : '';
  let host = 'docker.io';
  let repo = name;
  if (first.includes('.') || first.includes(':') || first === 'localhost') {
    host = first;
    repo = name.slice(slash + 1);
  }
  if (host === 'docker.io') {
    host = 'registry-1.docker.io';
    if (!repo.includes('/')) repo = `library/${repo}`;
  }
  return { host, repo };
}

async function request(url, { method = 'GET', headers = {}, timeout = 60_000 } = {}) {
  try {
    return await fetch(url, { method, headers, signal: AbortSignal.timeout(timeout) });
  } catch (error) {
    throw new Error(`${method} ${url}: ${error.cause?.code ?? error.message}`);
  }
}

async function getBytes(url) {
  const response = await request(url, { timeout: 120_000 });
  if (!response.ok) throw new Error(`GET ${url}: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

async function getText(url) {
  return (await getBytes(url)).toString('utf8');
}

// Minimal tar reader for regular files: ustar names (with prefix), GNU long names and pax paths.
function readTar(buffer) {
  const files = new Map();
  let offset = 0;
  let longName = null;
  let paxPath = null;
  while (offset + 512 <= buffer.length) {
    const header = buffer.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const field = (start, length) => header.subarray(start, start + length).toString('utf8').replace(/\0.*$/s, '');
    const size = parseTarNumber(header.subarray(124, 136));
    const type = String.fromCharCode(header[156] || 0x30);
    const dataStart = offset + 512;
    if (dataStart + size > buffer.length) throw new Error('the chart archive is truncated');
    const data = buffer.subarray(dataStart, dataStart + size);
    offset = dataStart + Math.ceil(size / 512) * 512;

    if (type === 'L') {
      longName = data.toString('utf8').replace(/\0.*$/s, '');
      continue;
    }
    if (type === 'x') {
      paxPath = parsePaxPath(data) ?? paxPath;
      continue;
    }
    if (type === 'g' || type === 'K') continue;

    let name = longName ?? paxPath;
    if (name === null) {
      name = field(0, 100);
      const prefix = field(345, 155);
      if (field(257, 5) === 'ustar' && prefix) name = `${prefix}/${name}`;
    }
    longName = null;
    paxPath = null;
    if (type === '0') files.set(name.replace(/^\.\//, ''), data);
  }
  return files;
}

function parseTarNumber(bytes) {
  if (bytes[0] & 0x80) throw new Error('base-256 tar sizes are not supported');
  const digits = bytes.toString('ascii').replace(/\0.*$/s, '').trim();
  if (digits === '') return 0;
  if (!/^[0-7]+$/.test(digits)) throw new Error(`invalid tar size "${digits}"`);
  return parseInt(digits, 8);
}

function parsePaxPath(data) {
  let path = null;
  for (let at = 0; at < data.length; ) {
    const space = data.indexOf(0x20, at);
    const length = Number(data.subarray(at, space).toString('ascii'));
    if (space < 0 || !(length > 0)) throw new Error('invalid pax header');
    const record = data.subarray(space + 1, at + length - 1).toString('utf8');
    if (record.startsWith('path=')) path = record.slice(5);
    at += length;
  }
  return path;
}

// Every document of a YAML stream as plain values. A syntax error, or any error the parser reports,
// fails the run.
function parseDocuments(text, source) {
  return YAML.parseAllDocuments(text)
    .map((doc) => {
      if (doc.errors.length > 0) throw new Error(`${source}: ${doc.errors[0].message}`);
      return doc.toJS();
    })
    .filter((doc) => doc !== null);
}

function getPath(object, path) {
  return path.split('.').reduce((node, key) => (node && typeof node === 'object' ? node[key] : undefined), object);
}

function onlyOne(items, what) {
  if (items.length !== 1) throw new Error(`expected one ${what}, found ${items.length}`);
  return items[0];
}

function normalizeRef(ref) {
  return ref.replace(/^docker\.io\//, '');
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

main().catch((error) => {
  console.error(`renovate-chart-images: ${error.message}`);
  process.exitCode = 1;
});
