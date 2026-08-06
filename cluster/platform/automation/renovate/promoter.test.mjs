#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  extractChangedImageReferences,
  extractChartVersion,
  extractImageReferences,
  extractRenderedImages,
  extractRegistryCredentials,
  extractSeedImageReferences,
  extractValueFiles,
  isEligibleRenovatePullRequest,
  isMainModule,
  mapImageReference,
} from './promoter.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const catalog = JSON.parse(fs.readFileSync(path.join(directory, 'artifact-sources.json'), 'utf8'));

assert.deepEqual(
  mapImageReference(
    'harbor.rcrumana.xyz/mirror/linuxserver/sonarr:4.0.19.2944-ls300@sha256:' + 'a'.repeat(64),
    catalog,
  ),
  {
    source: 'lscr.io/linuxserver/sonarr:4.0.19.2944-ls300@sha256:' + 'a'.repeat(64),
    destination: 'harbor.rcrumana.xyz/mirror/linuxserver/sonarr:4.0.19.2944-ls300@sha256:' + 'a'.repeat(64),
  },
);

assert.deepEqual(
  mapImageReference('quay.io/prometheus/prometheus:v3.7.0', catalog),
  {
    source: 'quay.io/prometheus/prometheus:v3.7.0',
    destination: 'harbor.rcrumana.xyz/mirror/prometheus/prometheus:v3.7.0',
  },
);

assert.deepEqual(
  mapImageReference('busybox:1.38', catalog),
  {
    source: 'docker.io/library/busybox:1.38',
    destination: 'harbor.rcrumana.xyz/mirror/library/busybox:1.38',
  },
);

assert.equal(mapImageReference('ghcr.io/unknown/example:1.0.0', catalog), null);

assert.deepEqual(
  extractRegistryCredentials(JSON.stringify({
    auths: {
      'harbor.rcrumana.xyz': {
        auth: Buffer.from('robot$renovate:test-password').toString('base64'),
      },
    },
  }), 'harbor.rcrumana.xyz'),
  { username: 'robot$renovate', password: 'test-password' },
);

const splitValues = `
image:
  repository: harbor.rcrumana.xyz/mirror/rook/ceph
  tag: v1.20.3
sidecar:
  image: harbor.rcrumana.xyz/mirror/library/busybox:1.38@sha256:${'b'.repeat(64)}
custom:
  registry: harbor.rcrumana.xyz
  repository: apps-private/nextcloud
  tag: 33.0.7-user_oidc-8.10.1@sha256:${'c'.repeat(64)}
`;
assert.deepEqual(extractImageReferences(splitValues), [
  `harbor.rcrumana.xyz/apps-private/nextcloud:33.0.7-user_oidc-8.10.1@sha256:${'c'.repeat(64)}`,
  `harbor.rcrumana.xyz/mirror/library/busybox:1.38@sha256:${'b'.repeat(64)}`,
  'harbor.rcrumana.xyz/mirror/rook/ceph:v1.20.3',
]);

const application = `
sources:
  - repoURL: harbor.rcrumana.xyz/thirdparty-charts
    chart: kube-prometheus-stack
    targetRevision: "88.1.5"
    helm:
      valueFiles:
        - $values/cluster/platform/observability/monitoring/values.yaml
`;
assert.equal(extractChartVersion(application, 'kube-prometheus-stack'), '88.1.5');
assert.deepEqual(extractValueFiles(application), [
  'cluster/platform/observability/monitoring/values.yaml',
]);

const rendered = `
containers:
  - image: quay.io/prometheus/prometheus:v3.7.0
  - image: "harbor.rcrumana.xyz/mirror/grafana/grafana:12.1.0"
  - image: harbor.rcrumana.xyz/proxy-dockerhub/library/busybox:1.38
`;
assert.deepEqual(extractRenderedImages(rendered), [
  'harbor.rcrumana.xyz/mirror/grafana/grafana:12.1.0',
  'harbor.rcrumana.xyz/proxy-dockerhub/library/busybox:1.38',
  'quay.io/prometheus/prometheus:v3.7.0',
]);

assert.deepEqual(extractSeedImageReferences(`
EXTRA_IMAGES=(
  "quay.io/prometheus-operator/prometheus-config-reloader:v0.88.0"
  "docker.io/library/busybox:1.38"
)
`), [
  'docker.io/library/busybox:1.38',
  'quay.io/prometheus-operator/prometheus-config-reloader:v0.88.0',
]);

assert.deepEqual(extractChangedImageReferences(`
initContainers:
  - image: harbor.rcrumana.xyz/mirror/library/busybox:1.38
image:
  repository: harbor.rcrumana.xyz/mirror/library/nextcloud
  tag: 33.0.0-apache
`, `
initContainers:
  - image: harbor.rcrumana.xyz/mirror/library/busybox:1.36
image:
  repository: harbor.rcrumana.xyz/mirror/library/nextcloud
  tag: 33.0.0-apache
`), [
  'harbor.rcrumana.xyz/mirror/library/busybox:1.38',
]);

const eligiblePr = {
  state: 'open',
  merged_at: null,
  user: { login: 'rrumana' },
  head: {
    ref: 'renovate/media-applications',
    repo: { full_name: 'rrumana/k8s-cluster' },
  },
  base: { ref: 'main' },
};
const eligibilityOptions = {
  allowedAuthor: 'rrumana',
  repository: 'rrumana/k8s-cluster',
  recoveryCutoff: Date.parse('2026-08-06T08:00:00Z'),
};
assert.equal(isEligibleRenovatePullRequest(eligiblePr, eligibilityOptions), true);
assert.equal(isEligibleRenovatePullRequest({
  ...eligiblePr,
  state: 'closed',
  merged_at: '2026-08-06T09:00:00Z',
}, eligibilityOptions), true);
assert.equal(isEligibleRenovatePullRequest({
  ...eligiblePr,
  state: 'closed',
  merged_at: '2026-08-05T09:00:00Z',
}, eligibilityOptions), false);
assert.equal(isEligibleRenovatePullRequest({
  ...eligiblePr,
  state: 'closed',
  merged_at: null,
}, eligibilityOptions), false);
assert.equal(isEligibleRenovatePullRequest({
  ...eligiblePr,
  user: { login: 'unexpected-user' },
}, eligibilityOptions), false);

const symlinkDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'renovate-promoter-test-'));
const symlinkPath = path.join(symlinkDirectory, 'promoter.mjs');
const promoterPath = path.join(directory, 'promoter.mjs');
fs.symlinkSync(promoterPath, symlinkPath);
assert.equal(isMainModule(new URL('./promoter.mjs', import.meta.url).href, symlinkPath), true);
assert.equal(isMainModule(new URL('./promoter.mjs', import.meta.url).href, null), false);
fs.rmSync(symlinkDirectory, { recursive: true });

console.log('Harbor promoter parser tests passed.');
