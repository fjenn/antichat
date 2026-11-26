/**
 * A recogniser with a backup: the phone's own (Apple's SpeechTranscriber)
 * first, Whisper when it fails.
 *
 * A failure of the first one — it cannot load, refuses the audio, reports an
 * error, or throws on finish — never reaches the user while the second can
 * take over: the session keeps every chunk it was given, starts the backup,
 * replays the audio into it and carries on there. From then on the backup is
 * used for every later dictation. Only when the backup fails too does the
 * session report an error (the dictation bar's inline error row).
 */
import {voiceError} from '../types';
import type {
  SttAdapter,
  SttAdapterId,
  SttEvent,
  SttOptions,
  SttResult,
  SttSession,
} from './types';

export class FallbackSttAdapter implements SttAdapter {
  private primaryBroken = false;
  private backup: Promise<SttAdapter> | null = null;
  private backupReady: SttAdapter | null = null;

  constructor(
    private readonly primary: SttAdapter,
    /** Builds the backup; it is prepared here before use. */
    private readonly makeBackup: () => Promise<SttAdapter>,
    private readonly log: (message: string) => void = message =>
      console.log(message),
  ) {}

  get id(): SttAdapterId {
    return this.primaryBroken
      ? (this.backupReady?.id ?? 'whisper')
      : this.primary.id;
  }

  get trueStreaming(): boolean {
    return this.primaryBroken
      ? (this.backupReady?.trueStreaming ?? false)
      : this.primary.trueStreaming;
  }

  /** The first recogniser failed; later dictations go to the backup. */
  markBroken(reason: unknown): void {
    if (!this.primaryBroken) {
      this.primaryBroken = true;
      this.log(
        `[voice] ${this.primary.id} recogniser failed, using backup: ${String(reason)}`,
      );
      this.primary.release().catch(() => {});
    }
  }

  get usingBackup(): boolean {
    return this.primaryBroken;
  }

  backupFor(language: string): Promise<SttAdapter> {
    this.backup ??= (async () => {
      const adapter = await this.makeBackup();
      await adapter.prepare(language);
      this.backupReady = adapter;
      return adapter;
    })().catch(error => {
      this.backup = null;
      throw error;
    });
    return this.backup;
  }

  async prepare(language: string): Promise<void> {
    if (!this.primaryBroken) {
      try {
        await this.primary.prepare(language);
        return;
      } catch (error) {
        this.markBroken(error);
      }
    }
    await this.backupFor(language);
  }

  async release(): Promise<void> {
    await this.primary.release().catch(() => {});
    await this.backupReady?.release().catch(() => {});
  }

  start(options: SttOptions, onEvent: (event: SttEvent) => void): SttSession {
    return new FallbackSession(this, this.primary, options, onEvent);
  }

  async transcribe(
    pcm: Int16Array,
    options: Pick<SttOptions, 'language' | 'punctuate' | 'context'>,
  ): Promise<{text: string; language: string}> {
    if (!this.primaryBroken) {
      try {
        return await this.primary.transcribe(pcm, options);
      } catch (error) {
        this.markBroken(error);
      }
    }
    return (await this.backupFor(options.language)).transcribe(pcm, options);
  }
}

/** 20 minutes of 50 ms chunks. */
const MAX_REPLAY_CHUNKS = 24_000;

class FallbackSession implements SttSession {
  private readonly audio: Int16Array[] = [];
  private current: SttSession | null = null;
  private mode: 'primary' | 'switching' | 'backup' | 'failed';
  private switching: Promise<void> = Promise.resolve();
  private failure: unknown = null;
  private cancelled = false;

  constructor(
    private readonly owner: FallbackSttAdapter,
    primary: SttAdapter,
    private readonly options: SttOptions,
    private readonly onEvent: (event: SttEvent) => void,
  ) {
    if (owner.usingBackup) {
      this.mode = 'switching';
      this.startBackup();
      return;
    }
    this.mode = 'primary';
    try {
      const session = primary.start(options, event => {
        if (this.mode !== 'primary' || this.current !== session) {
          return;
        }
        if (event.type === 'error') {
          this.switchOver(event.error.detail ?? event.error.code);
          return;
        }
        this.forward(event);
      });
      this.current = session;
    } catch (error) {
      this.switchOver(error);
    }
  }

  get text(): string {
    if (this.mode === 'switching') {
      return '';
    }
    try {
      return this.current?.text ?? '';
    } catch {
      return '';
    }
  }

  push(pcm: Int16Array): void {
    if (this.cancelled) {
      return;
    }
    // Kept for a replay into the backup until the backup has it all.
    if (this.mode !== 'backup' && this.audio.length < MAX_REPLAY_CHUNKS) {
      this.audio.push(pcm);
    }
    if (this.mode === 'switching' || this.mode === 'failed') {
      return;
    }
    try {
      this.current?.push(pcm);
    } catch (error) {
      if (this.mode === 'primary') {
        this.switchOver(error);
      }
    }
  }

  async snapshot(): Promise<string> {
    await this.switching;
    try {
      return (await this.current?.snapshot()) ?? '';
    } catch {
      return this.text;
    }
  }

  async finish(): Promise<SttResult> {
    if (this.mode === 'primary' && this.current) {
      const session = this.current;
      try {
        const result = await session.finish();
        if (this.mode === 'primary') {
          return result;
        }
      } catch (error) {
        if (this.mode === 'primary') {
          this.switchOver(error);
        }
      }
    }
    await this.switching;
    if (this.mode === 'backup' && this.current) {
      return this.current.finish();
    }
    throw this.failure instanceof Error
      ? this.failure
      : new Error(String(this.failure ?? 'dictation failed'));
  }

  cancel(): void {
    this.cancelled = true;
    try {
      this.current?.cancel();
    } catch {}
    this.current = null;
  }

  private forward(event: SttEvent): void {
    try {
      this.onEvent(event);
    } catch (error) {
      console.warn(`[voice] dictation event handler: ${error}`);
    }
  }

  private switchOver(reason: unknown): void {
    if (this.mode !== 'primary') {
      return;
    }
    this.mode = 'switching';
    const old = this.current;
    this.current = null;
    try {
      old?.cancel();
    } catch {}
    this.owner.markBroken(reason);
    this.startBackup();
  }

  private startBackup(): void {
    this.switching = this.owner
      .backupFor(this.options.language)
      .then(adapter => {
        if (this.cancelled) {
          return;
        }
        const session = adapter.start(this.options, event => {
          if (this.current === session) {
            this.forward(event);
          }
        });
        this.current = session;
        this.mode = 'backup';
        for (const chunk of this.audio) {
          session.push(chunk);
        }
        this.audio.length = 0;
      })
      .catch(error => {
        this.mode = 'failed';
        this.failure = error;
        this.forward({
          type: 'error',
          error: voiceError('failed', error),
        });
      });
  }
}
