#!/usr/bin/env node
// Generates the data behind Settings > About > Open-source licences.
//
//   node tools/antichat/generate-licences.mjs
//
// Walks the dependency tree of what ships in the app (package.json
// `dependencies` and everything they depend on, as installed in
// node_modules) and writes src/antichat/ui/settings/about/licences.json:
// every package with its version, licence, project page, copyright lines and
// licence text. Licence bodies are stored once and shared (most packages use
// the same MIT text with a different copyright line).
//
// Run it again after the integration lane changes dependencies. The Jest
// suite fails when a direct dependency is missing from the file.
import {createHash} from 'node:crypto';
import {existsSync, readFileSync, readdirSync, writeFileSync} from 'node:fs';
import {dirname, join, resolve} from 'node:path';

const root = resolve(dirname(process.argv[1]), '../..');
const out = join(root, 'src/antichat/ui/settings/about/licences.json');
const readJson = path => JSON.parse(readFileSync(path, 'utf8'));

/** Node's resolution: the nearest node_modules/<name> going up from `from`. */
function findPackage(name, from) {
  let dir = from;
  for (;;) {
    const candidate = join(dir, 'node_modules', name, 'package.json');
    if (existsSync(candidate)) {
      return dirname(candidate);
    }
    const parent = dirname(dir);
    if (parent === dir || !dir.startsWith(root)) {
      return null;
    }
    dir = parent;
  }
}

function licenceOf(pkg) {
  const value = pkg.license ?? pkg.licenses;
  if (!value) {
    return 'Unknown';
  }
  if (typeof value === 'string') {
    return value;
  }
  if (Array.isArray(value)) {
    return value.map(item => item.type ?? item).join(' OR ');
  }
  return value.type ?? 'Unknown';
}

function urlOf(pkg) {
  const repo =
    typeof pkg.repository === 'string' ? pkg.repository : pkg.repository?.url;
  let url = pkg.homepage || repo || '';
  url = url
    .replace(/^git\+/, '')
    .replace(/^git:\/\//, 'https://')
    .replace(/^git@github\.com:/, 'https://github.com/')
    .replace(/^github:/, 'https://github.com/')
    .replace(/\.git$/, '');
  if (/^[\w.-]+\/[\w.-]+$/.test(url)) {
    url = `https://github.com/${url}`;
  }
  return /^https?:\/\//.test(url) ? url : '';
}

const LICENCE_FILE = /^(licen[cs]e|copying|notice)([.-].*)?$/i;

function licenceText(dir) {
  const names = readdirSync(dir)
    .filter(name => LICENCE_FILE.test(name))
    .sort((a, b) => rank(a) - rank(b));
  for (const name of names) {
    try {
      const text = readFileSync(join(dir, name), 'utf8').trim();
      if (text.length > 0 && text.length < 60_000) {
        return text;
      }
    } catch {
      // A directory or unreadable file: try the next one.
    }
  }
  return '';
}

const rank = name => (/^licen[cs]e/i.test(name) ? 0 : /^copying/i.test(name) ? 1 : 2);

const COPYRIGHT_LINE = /^\s*(copyright\b|\(c\)|©)/i;

/** Split a licence into its copyright lines and the shared body. */
function splitLicence(text) {
  const copyright = [];
  const body = [];
  for (const line of text.replace(/\r\n?/g, '\n').split('\n')) {
    if (COPYRIGHT_LINE.test(line) && line.length < 200) {
      copyright.push(line.trim());
    } else {
      body.push(line.replace(/\s+$/, ''));
    }
  }
  return {
    copyright,
    body: body.join('\n').replace(/\n{3,}/g, '\n\n').trim(),
  };
}

const app = readJson(join(root, 'package.json'));
const direct = Object.keys(app.dependencies ?? {});
const seen = new Map();
const queue = direct.map(name => ({name, from: root}));

while (queue.length > 0) {
  const {name, from} = queue.shift();
  const dir = findPackage(name, from);
  if (!dir) {
    continue;
  }
  const pkg = readJson(join(dir, 'package.json'));
  const key = `${pkg.name}@${pkg.version}`;
  if (seen.has(key)) {
    continue;
  }
  seen.set(key, {pkg, dir});
  for (const dependency of Object.keys({
    ...pkg.dependencies,
    ...pkg.optionalDependencies,
  })) {
    queue.push({name: dependency, from: dir});
  }
}

const texts = {};
const packages = [...seen.values()]
  .map(({pkg, dir}) => {
    const {copyright, body} = splitLicence(licenceText(dir));
    let text;
    if (body) {
      text = createHash('sha1').update(body).digest('hex').slice(0, 10);
      texts[text] = body;
    }
    return {
      name: pkg.name,
      version: pkg.version,
      licence: licenceOf(pkg),
      ...(urlOf(pkg) ? {url: urlOf(pkg)} : null),
      ...(copyright.length ? {copyright: copyright.slice(0, 6)} : null),
      ...(text ? {text} : null),
      ...(direct.includes(pkg.name) ? {direct: true} : null),
    };
  })
  .sort(
    (a, b) =>
      a.name.localeCompare(b.name, 'en') ||
      a.version.localeCompare(b.version, 'en', {numeric: true}),
  );

writeFileSync(out, `${JSON.stringify({packages, texts})}\n`);
const kb = Math.round(readFileSync(out).length / 1024);
console.log(
  `${packages.length} packages (${direct.length} direct), ` +
    `${Object.keys(texts).length} licence texts, ${kb} KB -> ${out}`,
);
