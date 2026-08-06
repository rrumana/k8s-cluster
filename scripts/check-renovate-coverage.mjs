#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const catalogPath = path.join(
  repoRoot,
  'cluster/platform/automation/renovate/artifact-sources.json',
);
const renovatePath = path.join(repoRoot, 'renovate.json');
const failures = [];

function fail(message) {
  failures.push(message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function walk(directory) {
  const files = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (entry.name === '.git') continue;
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) files.push(...walk(fullPath));
    else files.push(fullPath);
  }
  return files;
}

function relative(file) {
  return path.relative(repoRoot, file).replaceAll(path.sep, '/');
}

const catalog = readJson(catalogPath);
const renovate = readJson(renovatePath);

if (catalog.schemaVersion !== 1) fail(`unsupported artifact catalog schema: ${catalog.schemaVersion}`);

const destinationPrefixes = new Set();
for (const mapping of catalog.imageMappings) {
  if (!mapping.destinationPrefix.endsWith('/')) {
    fail(`image destination prefix must end in '/': ${mapping.destinationPrefix}`);
  }
  if (!mapping.sourcePrefix.endsWith('/')) {
    fail(`image source prefix must end in '/': ${mapping.sourcePrefix}`);
  }
  if (destinationPrefixes.has(mapping.destinationPrefix)) {
    fail(`duplicate image destination prefix: ${mapping.destinationPrefix}`);
  }
  destinationPrefixes.add(mapping.destinationPrefix);

  const expectedDescription = `Upstream mapping: ${mapping.destinationPrefix} -> ${mapping.sourcePrefix}`;
  const rule = renovate.packageRules.find((candidate) => candidate.description === expectedDescription);
  if (!rule) {
    fail(`renovate.json has no package rule for ${mapping.destinationPrefix}`);
    continue;
  }
  if (!rule.matchPackageNames?.includes(`${mapping.destinationPrefix}**`)) {
    fail(`package rule does not match ${mapping.destinationPrefix}**`);
  }
  if (!rule.overridePackageName?.includes(mapping.sourcePrefix)) {
    fail(`package rule for ${mapping.destinationPrefix} does not resolve to ${mapping.sourcePrefix}`);
  }
  if (!rule.registryUrls?.includes(mapping.registryUrl)) {
    fail(`package rule for ${mapping.destinationPrefix} is missing ${mapping.registryUrl}`);
  }
}

const scanRoots = ['cluster', 'scripts'].map((item) => path.join(repoRoot, item));
const scannedFiles = scanRoots.flatMap(walk).filter((file) =>
  /\.(?:ya?ml|sh|json|md)$/.test(file) || /(?:^|\/)Dockerfile[^/]*$/.test(file),
);
const mirrorPattern = /harbor\.rcrumana\.xyz\/mirror\/[A-Za-z0-9._%()/-]+/g;

for (const file of scannedFiles) {
  const contents = fs.readFileSync(file, 'utf8');
  for (const match of contents.matchAll(mirrorPattern)) {
    const repository = match[0].replace(/\/$/, '');
    if (!catalog.imageMappings.some((mapping) => `${repository}/`.startsWith(mapping.destinationPrefix))) {
      fail(`${relative(file)} uses an unmapped Harbor mirror repository: ${repository}`);
    }
  }
}

const chartPaths = new Map();
for (const chart of catalog.charts) {
  const expectedDatasource = chart.upstreamType === 'oci' ? 'docker' : 'helm';
  const expectedDependency = chart.upstreamType === 'oci'
    ? chart.upstreamRepository.replace(/^oci:\/\//, '')
    : chart.name;
  const paths = [chart.applicationPath, ...(chart.additionalApplicationPaths ?? [])];
  for (const applicationPath of paths) {
    const key = `${applicationPath}:${chart.name}`;
    if (chartPaths.has(key)) fail(`duplicate chart catalog entry: ${key}`);
    chartPaths.set(key, chart);
    const fullPath = path.join(repoRoot, applicationPath);
    if (!fs.existsSync(fullPath)) {
      fail(`chart application does not exist: ${applicationPath}`);
      continue;
    }
    const contents = fs.readFileSync(fullPath, 'utf8');
    if (!contents.includes('repoURL: harbor.rcrumana.xyz/thirdparty-charts')) {
      fail(`${applicationPath} is no longer a thirdparty-charts application`);
    }
    if (!new RegExp(`chart:\\s*["']?${chart.name.replaceAll('-', '\\-')}["']?`).test(contents)) {
      fail(`${applicationPath} does not declare chart ${chart.name}`);
    }
    if (!contents.includes(
      `# renovate: datasource=${expectedDatasource} depName=${expectedDependency}`,
    )) {
      fail(`${applicationPath} lacks the upstream Renovate annotation for ${chart.name}`);
    }
  }

  const rule = renovate.packageRules.find((candidate) =>
    candidate.matchDatasources?.includes(expectedDatasource) &&
    candidate.matchPackageNames?.includes(expectedDependency) &&
    candidate.registryUrls?.some((url) =>
      chart.upstreamRepository.replace(/^oci:\/\//, 'https://').startsWith(url.replace(/\/$/, '')),
    ),
  );
  if (!rule) fail(`renovate.json has no upstream ${expectedDatasource} rule for ${chart.name}`);
}

const disabledLocalChartRule = renovate.packageRules.find((rule) =>
  rule.matchDatasources?.includes('docker') &&
  rule.matchPackageNames?.includes('harbor.rcrumana.xyz/thirdparty-charts/**') &&
  rule.enabled === false,
);
if (!disabledLocalChartRule) {
  fail('renovate.json must disable built-in Harbor OCI chart lookups');
}

for (const manualImage of catalog.manualImages ?? []) {
  if (!manualImage.reason) fail(`manual image lacks a reason: ${manualImage.destinationRepository}`);
  const isPrivateImage = manualImage.destinationRepository.startsWith(
    'harbor.rcrumana.xyz/apps-private/',
  );
  const hasMirrorMapping = catalog.imageMappings.some((mapping) =>
    `${manualImage.destinationRepository}/`.startsWith(mapping.destinationPrefix),
  );
  if (!isPrivateImage && !hasMirrorMapping) {
    fail(`manual image has no source namespace mapping: ${manualImage.destinationRepository}`);
  }
}

for (const file of scannedFiles.filter((candidate) => candidate.includes('/cluster/platform/gitops/argocd/apps/'))) {
  const contents = fs.readFileSync(file, 'utf8');
  if (!contents.includes('repoURL: harbor.rcrumana.xyz/thirdparty-charts')) continue;
  const charts = [...contents.matchAll(/^\s*chart:\s*["']?([^\s"']+)/gm)].map((match) => match[1]);
  for (const chart of charts) {
    const key = `${relative(file)}:${chart}`;
    if (!chartPaths.has(key)) fail(`mirrored chart is missing from artifact catalog: ${key}`);
  }
}

const allText = scannedFiles.map((file) => fs.readFileSync(file, 'utf8')).join('\n');
const exceptionReferences = new Set();
for (const exception of catalog.mutableTagExceptions) {
  if (!exception.reason) fail(`mutable tag exception lacks a reason: ${exception.reference}`);
  if (exceptionReferences.has(exception.reference)) fail(`duplicate mutable tag exception: ${exception.reference}`);
  exceptionReferences.add(exception.reference);
  if (!allText.includes(exception.reference)) {
    fail(`stale mutable tag exception is not present in cluster/scripts: ${exception.reference}`);
  }
}

const mutablePattern = /(?:image:\s*|repository:\s*)["']?([^\s"']+:(?:latest|stable|main|edge|2-rootless))(?:@sha256:[a-f0-9]{64})?["']?/g;
for (const file of scannedFiles) {
  const contents = fs.readFileSync(file, 'utf8');
  for (const match of contents.matchAll(mutablePattern)) {
    const whole = match[0];
    const reference = match[1];
    if (whole.includes('@sha256:')) continue;
    if (!exceptionReferences.has(reference)) {
      fail(`${relative(file)} has an unpinned mutable image tag without an exception: ${reference}`);
    }
  }
}

const manualTrackPath = path.join(repoRoot, 'dependencies/renovate-manual-tracks.yaml');
const manualTracks = fs.readFileSync(manualTrackPath, 'utf8');
for (const requiredTrack of [
  'cloudnativePg',
  'snapshotController',
  'nextcloudBase',
  'nextcloudUserOidc',
  'unifiOsServer',
  'llamaSwap',
  'liteLlm',
  'hypermind',
  'vueTorrent',
  'jellyfinSsoPlugin',
  'harborVendoredChart',
  'ciliumBootstrapChart',
]) {
  if (!new RegExp(`^  ${requiredTrack}:`, 'm').test(manualTracks)) {
    fail(`manual compatibility track is missing: ${requiredTrack}`);
  }
}
const annotationCount = (manualTracks.match(/# renovate: datasource=/g) ?? []).length;
if (annotationCount < 12) fail(`manual compatibility tracks expose only ${annotationCount} Renovate dependencies`);

for (const requiredDisabledFile of [
  'cluster/platform/base/data/data-operators/postgres-operator/kustomization.yaml',
  'cluster/platform/base/kube-system/snapshot-controller/deployment-patch.yaml',
]) {
  const disabledRule = renovate.packageRules.find((rule) =>
    rule.matchDatasources?.includes('docker') &&
    rule.matchFileNames?.includes(requiredDisabledFile) &&
    rule.enabled === false,
  );
  if (!disabledRule) fail(`unsafe vendored-manifest image update is not disabled: ${requiredDisabledFile}`);
}

for (const requiredAnnotatedFile of [
  'cluster/bootstrap/kubeadm-config.yaml',
  'cluster/bootstrap/argocd/kustomization.yaml',
  'cluster/platform/base/networking/egress-qos/configmap.yaml',
  'cluster/platform/base/networking/egress-qos/daemonset.yaml',
  'scripts/seed-observability-prereqs.sh',
]) {
  const contents = fs.readFileSync(path.join(repoRoot, requiredAnnotatedFile), 'utf8');
  if (!contents.includes('# renovate: datasource=')) {
    fail(`hardcoded dependency file lacks a Renovate annotation: ${requiredAnnotatedFile}`);
  }
}

if (failures.length > 0) {
  console.error('Renovate coverage check failed:');
  for (const message of failures) console.error(`  - ${message}`);
  process.exit(1);
}

console.log(
  `Renovate coverage OK: ${catalog.imageMappings.length} image mappings, ` +
  `${catalog.charts.length} chart mappings, ${annotationCount} manual tracks.`,
);
