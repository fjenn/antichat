#!/usr/bin/env node
/**
 * Fails when a commit touches an upstream (PocketPal) file that is not on the
 * allow-list in docs/UPSTREAM-PATCHES.md.
 *
 *   node e2e/antichat/scripts/check-upstream-patches.mjs            # HEAD
 *   node e2e/antichat/scripts/check-upstream-patches.mjs <commit>   # one commit
 *   node e2e/antichat/scripts/check-upstream-patches.mjs <a>..<b>   # every commit in a range
 *   node e2e/antichat/scripts/check-upstream-patches.mjs --staged   # the index (pre-commit hook)
 *
 * A file passes when it is ours (the directories in docs/antichat/FORK.md) or
 * is named in the first column of the table in UPSTREAM-PATCHES.md. An entry
 * may contain "…" or "*" as a wildcard. Deleting an upstream file passes
 * only when its row says "(removed)" in the first cell: upstream code is
 * switched off, not removed.
 */
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const git = (...args) =>
  execFileSync('git', args, {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024});
const root = git('rev-parse', '--show-toplevel').trim();

/** Directories and files that are AntiChat's own. */
const OURS = [
  'src/antichat/',
  'ios/AntiChat',
  'android/app/src/main/java/com/pocketpalai/antichat/',
  'docs/antichat/',
  'docs/research/',
  'docs/PLAN.md',
  'docs/UPSTREAM-PATCHES.md',
  'tools/',
  'e2e/antichat/',
  'relay/',
];

export function allowListFrom(markdown) {
  const entries = [];
  const removable = new Set();
  for (const line of markdown.split('\n')) {
    if (!line.startsWith('|') || /^\|\s*-+/.test(line)) {
      continue;
    }
    const firstCell = line.split('|')[1] ?? '';
    for (const match of firstCell.matchAll(/`([^`]+)`/g)) {
      entries.push(match[1]);
      if (firstCell.includes('(removed)')) {
        removable.add(match[1]);
      }
    }
  }
  entries.removable = removable;
  return entries;
}

function toPattern(entry) {
  const escaped = entry
    .replace(/[.+?^${}()|[\]\\]/g, '\\$&')
    .replace(/…|\*/g, '.*');
  return new RegExp(`^${escaped}$`);
}

export function check(changes, allowList) {
  const patterns = allowList.map(toPattern);
  const problems = [];
  for (const {status, file} of changes) {
    if (OURS.some(prefix => file.startsWith(prefix))) {
      continue;
    }
    const listed = patterns.some(pattern => pattern.test(file));
    if (status === 'D' && allowList.removable?.has(file)) {
      continue;
    }
    if (status === 'D') {
      problems.push(`${file}: upstream file deleted`);
    } else if (!listed) {
      problems.push(`${file}: not in docs/UPSTREAM-PATCHES.md`);
    }
  }
  return problems;
}

function changesOf(diffArgs) {
  return git('diff', '--name-status', '--no-renames', ...diffArgs)
    .split('\n')
    .filter(Boolean)
    .map(line => {
      const [status, file] = line.split('\t');
      return {status: status[0], file};
    });
}

function main() {
  const target = process.argv[2] ?? 'HEAD';
  const allowList = allowListFrom(
    fs.readFileSync(path.join(root, 'docs/UPSTREAM-PATCHES.md'), 'utf8'),
  );
  let units;
  if (target === '--staged') {
    units = [{name: 'staged changes', changes: changesOf(['--cached'])}];
  } else {
    const commits = target.includes('..')
      ? git('rev-list', '--no-merges', target).split('\n').filter(Boolean)
      : [git('rev-parse', target).trim()];
    units = commits.map(commit => ({
      name: git('log', '-1', '--format=%h %s', commit).trim(),
      changes: changesOf([`${commit}^`, commit]),
    }));
  }
  let failed = false;
  for (const unit of units) {
    const problems = check(unit.changes, allowList);
    if (problems.length > 0) {
      failed = true;
      console.error(`✗ ${unit.name}`);
      problems.forEach(problem => console.error(`    ${problem}`));
    }
  }
  if (failed) {
    console.error(
      '\nUpstream files may only change through a marked ANTICHAT: edit that is listed in docs/UPSTREAM-PATCHES.md.',
    );
    process.exit(1);
  }
  console.log(`ok: ${units.length} commit(s) stay inside the allow-list`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}
