#!/usr/bin/env node

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import {
  extractChartVersion,
  extractRenderedImages,
  extractValueFiles,
  mapImageReference,
} from '../cluster/platform/automation/renovate/promoter.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const catalog = JSON.parse(fs.readFileSync(
  path.join(repoRoot, 'cluster/platform/automation/renovate/artifact-sources.json'),
  'utf8',
));

function command(name, args) {
  const result = spawnSync(name, args, {
    cwd: repoRoot,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const detail = [result.error?.message, result.stderr, result.stdout]
      .filter((value) => typeof value === 'string' && value.trim() !== '')
      .map((value) => value.trim())
      .join('\n');
    throw new Error(`${name} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return result.stdout;
}

if (command('helm', ['version', '--short']).trim() === '') {
  throw new Error('helm is required');
}

const failures = [];
for (const chart of catalog.charts) {
  const application = fs.readFileSync(path.join(repoRoot, chart.applicationPath), 'utf8');
  const version = extractChartVersion(application, chart.name);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), `chart-coverage-${chart.name}-`));

  try {
    const pullArgs = chart.upstreamType === 'oci'
      ? ['pull', chart.upstreamRepository, '--version', version, '--destination', directory]
      : ['pull', chart.name, '--repo', chart.upstreamRepository, '--version', version, '--destination', directory];
    command('helm', pullArgs);
    const archive = fs.readdirSync(directory)
      .map((file) => path.join(directory, file))
      .find((file) => file.endsWith('.tgz'));
    if (!archive) throw new Error('helm pull produced no chart archive');

    const valuesArgs = extractValueFiles(application).flatMap((file) => [
      '-f',
      path.join(repoRoot, file),
    ]);
    const rendered = command('helm', [
      'template', `coverage-${chart.name}`, archive, '--include-crds', ...valuesArgs,
    ]);

    const images = extractRenderedImages(rendered);
    for (const image of images) {
      if (image.startsWith(`${catalog.harborHost}/proxy-`)) continue;
      if (!mapImageReference(image, catalog)) {
        failures.push(`${chart.name}:${version} renders an unmapped image: ${image}`);
      }
    }
    console.log(`${chart.name}:${version}: ${images.length} rendered image reference(s)`);
  } catch (error) {
    failures.push(`${chart.name}:${version}: ${error.message}`);
  }
}

if (failures.length > 0) {
  console.error('Chart artifact coverage failed:');
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log('All mirrored charts and rendered images have upstream artifact mappings.');
