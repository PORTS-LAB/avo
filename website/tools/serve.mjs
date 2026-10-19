#!/usr/bin/env node
// Local development with no account and no npm packages:
//
//   node tools/serve.mjs [--port 8788] [--no-watch] [--out DIR]
//
// - Builds the site and serves it at http://localhost:8788/<base path>/ (the
//   path of siteUrl, so links work as they will on GitHub Pages).
// - Rebuilds when src/ or site.config.mjs change.

import { createServer } from 'node:http';
import { existsSync, watch } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { build, loadConfig, ROOT } from './build.mjs';

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
};

const SITE_PORT = Number(option('--port', 8788));
const DIST = path.resolve(option('--out', path.join(ROOT, 'dist')));

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.avif': 'image/avif',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

const config = await loadConfig();
const basePath = new URL(`${config.siteUrl.replace(/\/+$/, '')}/`).pathname; // `/` on the custom domain
const siteUrl = `http://localhost:${SITE_PORT}${basePath.replace(/\/$/, '')}`;

async function rebuild() {
  const started = Date.now();
  await build({ outDir: DIST, quiet: true, overrides: { siteUrl } });
  console.log(`built in ${Date.now() - started} ms`);
}

/**
 * Finds a file the way GitHub Pages does: index.html for a folder
 * (redirecting to add the trailing slash), otherwise `notFound` with
 * status 404.
 */
async function lookupFile(root, urlPath, notFound = null) {
  let rel;
  try {
    rel = decodeURIComponent(urlPath);
  } catch {
    rel = '/';
  }
  const file = path.normalize(path.join(root, rel));
  if (file !== root && !file.startsWith(root + path.sep)) return { status: 403, headers: {}, body: null };
  try {
    let target = file;
    const info = await stat(target);
    if (info.isDirectory()) {
      if (!urlPath.endsWith('/')) return { status: 301, headers: { location: `${urlPath}/` }, body: null };
      target = path.join(target, 'index.html');
    }
    return { status: 200, headers: { 'content-type': TYPES[path.extname(target)] || 'application/octet-stream', 'cache-control': 'no-store' }, body: await readFile(target) };
  } catch {
    if (notFound && existsSync(notFound)) return { status: 404, headers: { 'content-type': TYPES['.html'], 'cache-control': 'no-store' }, body: await readFile(notFound) };
    return { status: 404, headers: { 'content-type': 'text/plain; charset=utf-8' }, body: Buffer.from('not found') };
  }
}

await rebuild();

createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${SITE_PORT}`);
  let found;
  if (url.pathname.startsWith(basePath)) {
    found = await lookupFile(DIST, `/${url.pathname.slice(basePath.length)}`, path.join(DIST, '404.html'));
  } else if (url.pathname === '/' || url.pathname === basePath.replace(/\/$/, '')) {
    found = { status: 302, headers: { location: basePath }, body: null };
  } else {
    found = await lookupFile(DIST, '/404.html');
    found.status = 404;
  }
  res.writeHead(found.status, found.headers);
  res.end(found.body ?? undefined);
}).listen(SITE_PORT, '127.0.0.1');

console.log(`website: ${siteUrl}/   (Indonesian: ${siteUrl}/id/)`);

if (!flag('--no-watch')) {
  let timer = null;
  const onChange = (_event, file) => {
    if (file && /(^|[\\/])\.|~$/.test(file)) return;
    clearTimeout(timer);
    timer = setTimeout(() => rebuild().catch((error) => console.error(`build failed: ${error.message}`)), 120);
  };
  watch(path.join(ROOT, 'src'), { recursive: true }, onChange);
  watch(path.join(ROOT, 'site.config.mjs'), onChange);
}
