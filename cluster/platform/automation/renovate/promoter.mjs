#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const IMAGE_PATTERN = /harbor\.rcrumana\.xyz\/(?:mirror|apps-private)\/[A-Za-z0-9._/-]+(?::[A-Za-z0-9._+%-]+)?(?:@sha256:[a-f0-9]{64})?/g;

function stripQuotes(value) {
  return value.trim().replace(/^["']|["']$/g, '');
}

function normalizeSourceReference(reference) {
  if (reference.startsWith('harbor.rcrumana.xyz/')) return reference;
  const name = reference.split('@')[0].split(':')[0];
  const first = name.split('/')[0];
  if (!name.includes('/')) return `docker.io/library/${reference}`;
  if (!first.includes('.') && !first.includes(':') && first !== 'localhost') {
    return `docker.io/${reference}`;
  }
  return reference;
}

function hasVersion(reference) {
  const withoutDigest = reference.split('@')[0];
  return reference.includes('@sha256:') || withoutDigest.lastIndexOf(':') > withoutDigest.lastIndexOf('/');
}

function repositoryOnly(reference) {
  const withoutDigest = reference.split('@')[0];
  const lastSlash = withoutDigest.lastIndexOf('/');
  const lastColon = withoutDigest.lastIndexOf(':');
  return lastColon > lastSlash ? withoutDigest.slice(0, lastColon) : withoutDigest;
}

export function mapImageReference(reference, catalog) {
  const normalized = normalizeSourceReference(stripQuotes(reference));
  for (const mapping of catalog.imageMappings) {
    if (normalized.startsWith(mapping.destinationPrefix)) {
      return {
        source: mapping.sourcePrefix + normalized.slice(mapping.destinationPrefix.length),
        destination: normalized,
      };
    }
    if (normalized.startsWith(mapping.sourcePrefix)) {
      return {
        source: normalized,
        destination: mapping.destinationPrefix + normalized.slice(mapping.sourcePrefix.length),
      };
    }
  }
  return null;
}

export function extractImageReferences(contents) {
  const references = new Set();
  for (const match of contents.matchAll(IMAGE_PATTERN)) {
    if (hasVersion(match[0])) references.add(match[0]);
  }

  const splitPattern = /(?:repository|newName):\s*["']?(harbor\.rcrumana\.xyz\/mirror\/[A-Za-z0-9._/-]+)["']?([\s\S]{0,300}?)(?:tag|newTag):\s*["']?([^\s"']+)["']?/g;
  for (const match of contents.matchAll(splitPattern)) {
    if (!match[3].includes('%(') && !match[3].includes('{{')) {
      references.add(`${match[1]}:${match[3]}`);
    }
  }

  const registrySplitPattern = /registry:\s*["']?(harbor\.rcrumana\.xyz)["']?([\s\S]{0,200}?)repository:\s*["']?((?:mirror|apps-private)\/[A-Za-z0-9._/-]+)["']?([\s\S]{0,300}?)tag:\s*["']?([^\s"']+)["']?/g;
  for (const match of contents.matchAll(registrySplitPattern)) {
    if (!match[5].includes('%(') && !match[5].includes('{{')) {
      references.add(`${match[1]}/${match[3]}:${match[5]}`);
    }
  }
  return [...references].sort();
}

export function extractRenderedImages(contents) {
  const references = new Set();
  const pattern = /^\s*(?:-\s*)?(?:image|imageName):\s*["']?([^\s"'#]+)["']?/gm;
  for (const match of contents.matchAll(pattern)) {
    if (!match[1].includes('{{') && hasVersion(match[1])) references.add(match[1]);
  }
  return [...references].sort();
}

export function extractSeedImageReferences(contents) {
  const references = new Set();
  const pattern = /["']((?:docker\.io|quay\.io|ghcr\.io|registry\.k8s\.io|cr\.fluentbit\.io)\/[A-Za-z0-9._/-]+(?::[A-Za-z0-9._+-]+)?(?:@sha256:[a-f0-9]{64})?)["']/g;
  for (const match of contents.matchAll(pattern)) {
    if (hasVersion(match[1])) references.add(match[1]);
  }
  return [...references].sort();
}

export function extractRegistryCredentials(dockerConfigContents, registry) {
  const dockerConfig = JSON.parse(dockerConfigContents);
  const entry = dockerConfig.auths?.[registry];
  if (!entry) throw new Error(`Docker config has no credentials for ${registry}`);

  if (entry.username && entry.password) {
    return { username: entry.username, password: entry.password };
  }
  if (entry.auth) {
    const decoded = Buffer.from(entry.auth, 'base64').toString('utf8');
    const separator = decoded.indexOf(':');
    if (separator > 0) {
      return {
        username: decoded.slice(0, separator),
        password: decoded.slice(separator + 1),
      };
    }
  }
  throw new Error(`Docker config credentials for ${registry} are incomplete`);
}

export function extractChartVersion(contents, chartName) {
  const lines = contents.split('\n');
  const chartIndex = lines.findIndex((line) =>
    new RegExp(`^\\s*chart:\\s*["']?${chartName.replaceAll('-', '\\-')}["']?\\s*$`).test(line),
  );
  if (chartIndex < 0) return null;
  for (let distance = 1; distance <= 8; distance += 1) {
    for (const index of [chartIndex - distance, chartIndex + distance]) {
      if (index < 0 || index >= lines.length) continue;
      const match = lines[index].match(/^\s*targetRevision:\s*["']?([^\s"']+)["']?/);
      if (match) return match[1];
    }
  }
  return null;
}

export function extractValueFiles(contents) {
  return [...new Set(
    [...contents.matchAll(/^\s*-\s+\$values\/([^\s]+)\s*$/gm)].map((match) => match[1]),
  )];
}

function command(commandName, args, options = {}) {
  const result = spawnSync(commandName, args, {
    encoding: 'utf8',
    env: process.env,
    input: options.input,
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0 && !options.allowFailure) {
    const detail = (result.stderr || result.stdout || '').trim();
    throw new Error(`${commandName} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`);
  }
  return result;
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

class GitHubClient {
  constructor(token, repository, apiUrl) {
    this.token = token;
    this.repository = repository;
    this.apiUrl = apiUrl.replace(/\/$/, '');
  }

  async request(endpoint, options = {}) {
    const response = await fetch(`${this.apiUrl}${endpoint}`, {
      method: options.method ?? 'GET',
      headers: {
        Accept: options.raw ? 'application/vnd.github.raw+json' : 'application/vnd.github+json',
        Authorization: `Bearer ${this.token}`,
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'renovate-harbor-promoter',
        ...(options.headers ?? {}),
      },
      body: options.body ? JSON.stringify(options.body) : undefined,
    });
    if (options.allowNotFound && response.status === 404) return null;
    if (!response.ok) {
      const detail = await response.text();
      throw new Error(`GitHub ${response.status} for ${endpoint}: ${detail.slice(0, 500)}`);
    }
    return options.raw ? response.text() : response.json();
  }

  async listOpenPullRequests() {
    return this.request(`/repos/${this.repository}/pulls?state=open&per_page=100`);
  }

  async listChangedFiles(number) {
    const files = [];
    for (let page = 1; ; page += 1) {
      const batch = await this.request(
        `/repos/${this.repository}/pulls/${number}/files?per_page=100&page=${page}`,
      );
      files.push(...batch);
      if (batch.length < 100) break;
    }
    return files;
  }

  async getFile(file, revision) {
    const encodedPath = file.split('/').map(encodeURIComponent).join('/');
    return this.request(
      `/repos/${this.repository}/contents/${encodedPath}?ref=${encodeURIComponent(revision)}`,
      { raw: true, allowNotFound: true },
    );
  }

  async setStatus(sha, state, description) {
    if (process.env.PROMOTER_DRY_RUN === 'true') {
      console.log(`[dry-run] status ${sha.slice(0, 12)} ${state}: ${description}`);
      return;
    }
    await this.request(`/repos/${this.repository}/statuses/${sha}`, {
      method: 'POST',
      body: {
        state,
        context: 'renovate/artifacts-promoted',
        description: description.slice(0, 140),
      },
    });
  }
}

class Promoter {
  constructor(catalog, github, harborCredentials) {
    this.catalog = catalog;
    this.github = github;
    this.harborCredentials = harborCredentials;
    this.dryRun = process.env.PROMOTER_DRY_RUN === 'true';
  }

  authenticate() {
    if (this.dryRun) return;
    command('crane', [
      'auth', 'login', this.catalog.harborHost,
      '--username', this.harborCredentials.username,
      '--password-stdin',
    ], { input: this.harborCredentials.password });
    command('helm', [
      'registry', 'login', this.catalog.harborHost,
      '--username', this.harborCredentials.username,
      '--password-stdin',
    ], { input: this.harborCredentials.password });
  }

  digest(reference, allowFailure = false) {
    const result = command('crane', ['digest', reference], { allowFailure });
    return result.status === 0 ? result.stdout.trim() : null;
  }

  promoteImage(reference) {
    const manualImage = this.catalog.manualImages?.find((candidate) =>
      repositoryOnly(reference) === candidate.destinationRepository,
    );
    if (manualImage) {
      if (this.dryRun) {
        console.log(`[dry-run] verify manually built image ${reference}`);
        return;
      }
      const existingDigest = this.digest(reference, true);
      if (!existingDigest) {
        throw new Error(`manually built Harbor image is missing: ${reference}`);
      }
      console.log(`verified manually built image: ${reference} (${existingDigest})`);
      return;
    }

    const mapped = mapImageReference(reference, this.catalog);
    if (!mapped) throw new Error(`no artifact mapping for image ${reference}`);

    if (this.dryRun) {
      console.log(`[dry-run] image ${mapped.source} -> ${mapped.destination}`);
      return;
    }

    const expectedDigest = mapped.destination.match(/@(sha256:[a-f0-9]{64})$/)?.[1] ?? null;
    const sourceDigest = this.digest(mapped.source);
    if (expectedDigest && expectedDigest !== sourceDigest) {
      throw new Error(`source digest mismatch for ${mapped.source}: expected ${expectedDigest}, got ${sourceDigest}`);
    }

    const destinationWithoutDigest = mapped.destination.split('@')[0];
    const destinationHasTag = destinationWithoutDigest.lastIndexOf(':') > destinationWithoutDigest.lastIndexOf('/');
    const destinationDigest = this.digest(
      destinationHasTag ? destinationWithoutDigest : mapped.destination,
      true,
    );
    if (destinationDigest === sourceDigest) {
      console.log(`image already promoted: ${mapped.destination}`);
      return;
    }

    let copyDestination = destinationHasTag
      ? destinationWithoutDigest
      : `${destinationWithoutDigest}:digest-${sourceDigest.slice('sha256:'.length, 'sha256:'.length + 16)}`;
    if (destinationDigest && destinationDigest !== sourceDigest) {
      if (!expectedDigest) {
        throw new Error(
          `refusing to overwrite ${mapped.destination}: Harbor has ${destinationDigest}, upstream has ${sourceDigest}`,
        );
      }
      const repository = repositoryOnly(copyDestination);
      copyDestination = `${repository}:digest-${sourceDigest.slice('sha256:'.length, 'sha256:'.length + 16)}`;
    }

    command('crane', ['copy', mapped.source, copyDestination]);
    const verifiedDigest = this.digest(`${repositoryOnly(copyDestination)}@${sourceDigest}`, true)
      ?? this.digest(copyDestination);
    if (verifiedDigest !== sourceDigest) {
      throw new Error(`Harbor digest verification failed for ${copyDestination}`);
    }
    console.log(`promoted image: ${mapped.source} -> ${copyDestination} (${sourceDigest})`);
  }

  async promoteChart(chart, version, appContents, headSha) {
    const taskDirectory = fs.mkdtempSync(path.join(os.tmpdir(), `renovate-${chart.name}-`));
    const upstreamDirectory = path.join(taskDirectory, 'upstream');
    const existingDirectory = path.join(taskDirectory, 'existing');
    fs.mkdirSync(upstreamDirectory);
    fs.mkdirSync(existingDirectory);

    const pullArgs = chart.upstreamType === 'oci'
      ? ['pull', chart.upstreamRepository, '--version', version, '--destination', upstreamDirectory]
      : ['pull', chart.name, '--repo', chart.upstreamRepository, '--version', version, '--destination', upstreamDirectory];
    command('helm', pullArgs);
    const chartArchive = fs.readdirSync(upstreamDirectory)
      .map((file) => path.join(upstreamDirectory, file))
      .find((file) => file.endsWith('.tgz'));
    if (!chartArchive) throw new Error(`helm pull produced no archive for ${chart.name} ${version}`);

    const valuesArgs = [];
    for (const valueFile of extractValueFiles(appContents)) {
      const contents = await this.github.getFile(valueFile, headSha);
      if (contents === null) throw new Error(`chart value file not found at PR head: ${valueFile}`);
      const localFile = path.join(taskDirectory, `values-${valuesArgs.length}.yaml`);
      fs.writeFileSync(localFile, contents);
      valuesArgs.push('-f', localFile);
    }

    const rendered = command('helm', [
      'template', `promoter-${chart.name}`, chartArchive, '--include-crds', ...valuesArgs,
    ]).stdout;
    for (const image of extractRenderedImages(rendered)) {
      if (image.startsWith(`${this.catalog.harborHost}/proxy-`)) continue;
      this.promoteImage(image);
    }

    const destination = `oci://${this.catalog.harborHost}/thirdparty-charts`;
    const existing = command('helm', [
      'pull', `${destination}/${chart.name}`, '--version', version, '--destination', existingDirectory,
    ], { allowFailure: true });
    if (existing.status === 0) {
      const existingArchive = fs.readdirSync(existingDirectory)
        .map((file) => path.join(existingDirectory, file))
        .find((file) => file.endsWith('.tgz'));
      if (existingArchive && sha256(existingArchive) === sha256(chartArchive)) {
        console.log(`chart already promoted: ${chart.name} ${version}`);
        return;
      }
      throw new Error(`refusing to overwrite chart ${chart.name}:${version} with different content`);
    }

    if (this.dryRun) {
      console.log(`[dry-run] chart ${chart.name}:${version} -> ${destination}`);
      return;
    }
    command('helm', ['push', chartArchive, destination]);
    console.log(`promoted chart: ${chart.name} ${version}`);
  }

  async processPullRequest(pr) {
    const sha = pr.head.sha;
    await this.github.setStatus(sha, 'pending', 'Checking required Harbor artifacts');
    try {
      const changedFiles = await this.github.listChangedFiles(pr.number);
      const paths = changedFiles.filter((file) => file.status !== 'removed').map((file) => file.filename);
      const contentsByPath = new Map();
      for (const file of paths) {
        const contents = await this.github.getFile(file, sha);
        if (contents !== null) contentsByPath.set(file, contents);
      }

      const images = new Set();
      for (const [file, contents] of contentsByPath.entries()) {
        if (file === 'dependencies/renovate-manual-tracks.yaml') continue;
        for (const image of extractImageReferences(contents)) images.add(image);
        if (file === 'scripts/seed-observability-prereqs.sh') {
          for (const image of extractSeedImageReferences(contents)) images.add(image);
        }
      }
      for (const image of [...images].sort()) this.promoteImage(image);

      for (const chart of this.catalog.charts) {
        const chartPaths = [chart.applicationPath, ...(chart.additionalApplicationPaths ?? [])];
        const changedPath = chartPaths.find((candidate) => contentsByPath.has(candidate));
        if (!changedPath) continue;
        const appContents = contentsByPath.get(changedPath);
        const version = extractChartVersion(appContents, chart.name);
        if (!version) throw new Error(`cannot extract ${chart.name} version from ${changedPath}`);
        await this.promoteChart(chart, version, appContents, sha);
      }

      const count = images.size;
      await this.github.setStatus(
        sha,
        'success',
        count > 0 ? `Verified/promoted ${count} explicit Harbor image artifact(s)` : 'No explicit Harbor image promotion required',
      );
    } catch (error) {
      await this.github.setStatus(sha, 'failure', `Harbor promotion failed: ${error.message}`);
      throw error;
    }
  }
}

async function main() {
  for (const required of [
    'GITHUB_TOKEN',
    'GITHUB_REPOSITORY',
    'HARBOR_DOCKER_CONFIG',
    'ARTIFACT_CATALOG',
  ]) {
    if (!process.env[required]) throw new Error(`missing required environment variable: ${required}`);
  }

  const catalog = JSON.parse(fs.readFileSync(process.env.ARTIFACT_CATALOG, 'utf8'));
  const github = new GitHubClient(
    process.env.GITHUB_TOKEN,
    process.env.GITHUB_REPOSITORY,
    process.env.GITHUB_API_URL ?? 'https://api.github.com',
  );
  const harborCredentials = extractRegistryCredentials(
    fs.readFileSync(process.env.HARBOR_DOCKER_CONFIG, 'utf8'),
    catalog.harborHost,
  );
  const promoter = new Promoter(catalog, github, harborCredentials);
  promoter.authenticate();

  const allowedAuthor = process.env.GITHUB_ALLOWED_AUTHOR ?? 'rrumana';
  const pullRequests = (await github.listOpenPullRequests()).filter((pr) =>
    pr.user.login === allowedAuthor &&
    pr.head.ref.startsWith('renovate/') &&
    pr.base.ref === 'main' &&
    pr.head.repo?.full_name === process.env.GITHUB_REPOSITORY,
  );

  let failed = false;
  for (const pr of pullRequests) {
    console.log(`processing Renovate PR #${pr.number}: ${pr.head.ref}`);
    try {
      await promoter.processPullRequest(pr);
    } catch (error) {
      failed = true;
      console.error(`PR #${pr.number}: ${error.stack ?? error.message}`);
    }
  }
  if (failed) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.stack ?? error.message);
    process.exitCode = 1;
  });
}
