#!/usr/bin/env node
/**
 * Compares two folders of screenshots and fails when a pair differs too much.
 *
 *   node e2e/antichat/scripts/diff-screenshots.mjs <baseline-dir> <current-dir>
 *        [--max 0.5]        largest share of differing pixels allowed, in percent
 *        [--tolerance 24]   per-channel difference (0-255) that still counts as equal
 *        [--ignore-top 6]   percent of the height to skip (status bar clock)
 *        [--ignore-bottom 3]
 *        [--update]         copy current over baseline instead of comparing
 *
 * Diff images (differing pixels in red over a dimmed copy) are written to
 * <current-dir>/_diff/. Uses odiff when `odiff-bin` is installed, otherwise a
 * built-in comparison on pngjs.
 *
 * Pixel comparison is for one platform against its own baseline. iOS against
 * Android is compared by eye on a contact sheet (contact-sheet.swift).
 */
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import {createRequire} from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const args = process.argv.slice(2);
const flag = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 ? Number(args[at + 1]) : fallback;
};
const positional = args.filter(
  (value, index) =>
    !value.startsWith('--') && !(args[index - 1] ?? '').startsWith('--'),
);
const [baselineDir, currentDir] = positional;
if (!baselineDir || !currentDir) {
  console.error(
    'usage: diff-screenshots.mjs <baseline-dir> <current-dir> [--max 0.5] [--update]',
  );
  process.exit(2);
}
const maxPercent = flag('max', 0.5);
const tolerance = flag('tolerance', 24);
const ignoreTop = flag('ignore-top', 6) / 100;
const ignoreBottom = flag('ignore-bottom', 3) / 100;

const pngs = dir =>
  fs.existsSync(dir)
    ? fs.readdirSync(dir).filter(name => name.endsWith('.png')).sort()
    : [];

if (args.includes('--update')) {
  fs.mkdirSync(baselineDir, {recursive: true});
  for (const name of pngs(currentDir)) {
    fs.copyFileSync(path.join(currentDir, name), path.join(baselineDir, name));
  }
  console.log(`baseline updated: ${pngs(currentDir).length} screenshots`);
  process.exit(0);
}

function odiffBinary() {
  try {
    const dir = path.dirname(require.resolve('odiff-bin/package.json'));
    const bin = path.join(dir, 'bin', 'odiff.exe');
    return fs.existsSync(bin) ? bin : null;
  } catch {
    return null;
  }
}

/** Returns the share of differing pixels in percent, or a reason it failed. */
function compareWithOdiff(bin, a, b, out, size) {
  const top = Math.round(size.height * ignoreTop);
  const bottom = Math.round(size.height * (1 - ignoreBottom));
  const result = spawnSync(
    bin,
    [
      a,
      b,
      out,
      '--threshold',
      String(tolerance / 255),
      '--antialiasing',
      '--parsable-stdout',
      '--ignore',
      `0:0-${size.width}:${top},0:${bottom}-${size.width}:${size.height}`,
    ],
    {encoding: 'utf8'},
  );
  if (result.status === 0) {
    return {percent: 0};
  }
  if (result.status === 21) {
    return {error: 'different size'};
  }
  const [, percent] = result.stdout.trim().split(';');
  return {percent: Number(percent)};
}

function compareWithPngjs(PNG, a, b, out) {
  const one = PNG.sync.read(fs.readFileSync(a));
  const two = PNG.sync.read(fs.readFileSync(b));
  if (one.width !== two.width || one.height !== two.height) {
    return {error: 'different size'};
  }
  const {width, height} = one;
  const diff = new PNG({width, height});
  const from = Math.round(height * ignoreTop);
  const to = Math.round(height * (1 - ignoreBottom));
  let different = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const changed =
        y >= from &&
        y < to &&
        (Math.abs(one.data[i] - two.data[i]) > tolerance ||
          Math.abs(one.data[i + 1] - two.data[i + 1]) > tolerance ||
          Math.abs(one.data[i + 2] - two.data[i + 2]) > tolerance);
      if (changed) {
        different += 1;
        diff.data.set([255, 0, 60, 255], i);
      } else {
        const grey =
          (two.data[i] + two.data[i + 1] + two.data[i + 2]) / 3 / 2 + 127;
        diff.data.set([grey, grey, grey, 255], i);
      }
    }
  }
  if (different > 0) {
    fs.writeFileSync(out, PNG.sync.write(diff));
  }
  return {percent: (different / (width * (to - from))) * 100};
}

const odiff = odiffBinary();
const {PNG} = require('pngjs');
const diffDir = path.join(currentDir, '_diff');
fs.rmSync(diffDir, {recursive: true, force: true});
fs.mkdirSync(diffDir, {recursive: true});

let failed = 0;
const names = pngs(baselineDir);
if (names.length === 0) {
  console.error(`no baseline screenshots in ${baselineDir}`);
  process.exit(2);
}
for (const name of names) {
  const a = path.join(baselineDir, name);
  const b = path.join(currentDir, name);
  if (!fs.existsSync(b)) {
    console.log(`MISSING  ${name}`);
    failed += 1;
    continue;
  }
  const out = path.join(diffDir, name);
  let result;
  if (odiff) {
    const header = PNG.sync.read(fs.readFileSync(a));
    result = compareWithOdiff(odiff, a, b, out, header);
  } else {
    result = compareWithPngjs(PNG, a, b, out);
  }
  if (result.error) {
    console.log(`FAIL     ${name}  (${result.error})`);
    failed += 1;
  } else if (result.percent > maxPercent) {
    console.log(`FAIL     ${name}  ${result.percent.toFixed(2)}% differs`);
    failed += 1;
  } else {
    console.log(`ok       ${name}  ${result.percent.toFixed(2)}%`);
  }
}
for (const name of pngs(currentDir)) {
  if (!names.includes(name)) {
    console.log(`NEW      ${name}  (no baseline)`);
  }
}
console.log(
  `${names.length - failed}/${names.length} match (max ${maxPercent}%, ${
    odiff ? 'odiff' : 'pngjs'
  })`,
);
process.exit(failed ? 1 : 0);
