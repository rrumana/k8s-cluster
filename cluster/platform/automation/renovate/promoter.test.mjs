#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  extractChartVersion,
  extractImageReferences,
  extractRenderedImages,
  extractRegistryCredentials,
  extractSeedImageReferences,
  extractValueFiles,
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

console.log('Harbor promoter parser tests passed.');
