import '../../../testing/setup';

import {translate} from '../../../locales';
import type {SetupStatus} from '../../models';
import {composerHint, setupWording, timeLeft} from '../wording';

const GB = 1000 ** 3;
const words = (status: SetupStatus) => setupWording(translate, status);

describe('setup wording', () => {
  it('says size, progress and time in one calm line', () => {
    const made = words({
      kind: 'downloading',
      fraction: 0.25,
      receivedBytes: 1.3 * GB,
      totalBytes: 5.2 * GB,
      etaSeconds: 230,
    });
    expect(made.title).toBe('Downloading your assistant');
    expect(made.line).toBe('1.3 of 5.2 GB · about 4 min left');
    expect(made.fraction).toBe(0.25);
    expect(made.tone).toBe('neutral');
  });

  it('leaves the estimate out when there is none', () => {
    expect(
      words({
        kind: 'downloading',
        fraction: 0,
        receivedBytes: 0,
        totalBytes: 5.2 * GB,
      }).line,
    ).toBe('0 B of 5.2 GB');
  });

  it('never names a model', () => {
    const statuses: SetupStatus[] = [
      {kind: 'preparing'},
      {kind: 'verifying', fraction: 0.5},
      {kind: 'loading'},
      {kind: 'ready'},
      {kind: 'missing', bytes: GB},
      {kind: 'waiting_wifi', bytes: GB},
      {kind: 'confirm_metered', noticeId: 'n', bytes: GB},
    ];
    for (const status of statuses) {
      const made = words(status);
      expect(`${made.title} ${made.line}`).not.toMatch(
        /gemma|qwen|lfm|gguf|model/i,
      );
    }
  });

  it('tells the three kinds of pause apart', () => {
    const paused = (reason: 'user' | 'offline' | 'metered') =>
      words({
        kind: 'paused',
        reason,
        fraction: 0.5,
        receivedBytes: GB,
        totalBytes: 2 * GB,
      });
    expect(paused('user').title).toBe('Download paused');
    expect(paused('offline').title).toBe('Waiting for a connection');
    expect(paused('offline').line).toContain('continues by itself');
    expect(paused('metered').title).toBe('Paused on mobile data');
    expect(paused('user').idle).toBe(true);
  });

  it('states the size before using mobile data', () => {
    expect(
      words({kind: 'confirm_metered', noticeId: 'n', bytes: 5.2 * GB}).line,
    ).toContain('5.2 GB');
  });

  it('gives every failure a title, a next step and the problem tone', () => {
    const reasons = [
      'offline',
      'storage_full',
      'download_failed',
      'checksum_mismatch',
      'out_of_memory',
      'load_failed',
      'file_missing',
    ] as const;
    for (const reason of reasons) {
      const made = words({kind: 'failed', reason, retryable: true});
      expect(made.title.length).toBeGreaterThan(5);
      expect(made.line.length).toBeGreaterThan(5);
      expect(made.tone).toBe('problem');
    }
    expect(
      words({
        kind: 'failed',
        reason: 'storage_full',
        retryable: false,
        neededBytes: 2.1 * GB,
      }).line,
    ).toBe('Free up 2.1 GB and try again.');
  });

  it('marks the ready moment as a success', () => {
    expect(words({kind: 'ready'}).tone).toBe('success');
  });
});

describe('timeLeft', () => {
  it('words singular and plural', () => {
    expect(timeLeft(translate, 60)).toBe('about 1 min left');
    expect(timeLeft(translate, 240)).toBe('about 4 min left');
    expect(timeLeft(translate, 30)).toBe('about 30 sec left');
    expect(timeLeft(translate, 3)).toBe('almost done');
    expect(timeLeft(translate, 3600)).toBe('about 1 hour left');
    expect(timeLeft(translate, undefined)).toBe('');
  });
});

describe('composer hint', () => {
  it('is silent once chat works', () => {
    expect(composerHint({kind: 'hidden'}, true)).toBeNull();
    expect(composerHint({kind: 'ready'}, true)).toBeNull();
  });

  it('says when the composer will answer', () => {
    expect(
      composerHint(
        {
          kind: 'downloading',
          fraction: 0.1,
          receivedBytes: 1,
          totalBytes: 10,
        },
        false,
      ),
    ).toBe('setup.composer.downloading');
    expect(composerHint({kind: 'loading'}, false)).toBe(
      'setup.composer.starting',
    );
    expect(composerHint({kind: 'missing', bytes: 1}, false)).toBe(
      'setup.composer.missing',
    );
    expect(
      composerHint(
        {
          kind: 'paused',
          reason: 'user',
          fraction: 0.1,
          receivedBytes: 1,
          totalBytes: 10,
        },
        false,
      ),
    ).toBe('setup.composer.paused');
  });
});
