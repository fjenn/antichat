import {
  createAppleSpeechBackend,
  wrapNativeTranscription,
} from '../bindings/appleSpeech';
import {FallbackSttAdapter} from '../stt/fallbackAdapter';
import type {SttAdapter, SttEvent, SttSession} from '../stt/types';
import {voiceError} from '../types';

const flush = () => new Promise(resolve => setTimeout(resolve, 0));
const chunk = () => new Int16Array(800);

/** A recogniser that "hears" one word per chunk, or fails on demand. */
function fakeAdapter(
  id: 'system' | 'whisper',
  behaviour: {
    failOnPush?: number;
    failPrepare?: boolean;
    failFinish?: boolean;
  } = {},
): SttAdapter & {sessions: number} {
  const adapter = {
    id,
    trueStreaming: id === 'system',
    sessions: 0,
    async prepare() {
      if (behaviour.failPrepare) {
        throw new Error(`${id} cannot load`);
      }
    },
    async release() {},
    start(_options: unknown, onEvent: (event: SttEvent) => void): SttSession {
      adapter.sessions++;
      let words = 0;
      return {
        get text() {
          return Array.from({length: words}, () => id).join(' ');
        },
        push() {
          words++;
          if (behaviour.failOnPush === words) {
            onEvent({type: 'error', error: voiceError('failed', 'boom')});
          }
        },
        snapshot: async () => '',
        async finish() {
          if (behaviour.failFinish) {
            throw new Error('finish failed');
          }
          return {
            text: Array.from({length: words}, () => id).join(' '),
            language: 'en',
            segments: [],
          };
        },
        cancel() {},
      };
    },
    async transcribe() {
      return {text: id, language: 'en'};
    },
  };
  return adapter;
}

describe('FallbackSttAdapter', () => {
  it('keeps the first recogniser while it works', async () => {
    const stt = new FallbackSttAdapter(
      fakeAdapter('system'),
      async () => fakeAdapter('whisper'),
      () => {},
    );
    await stt.prepare('en');
    const session = stt.start({language: 'en', mode: 'dictation'}, () => {});
    session.push(chunk());
    session.push(chunk());
    expect((await session.finish()).text).toBe('system system');
  });

  it('replays the audio into Whisper when Apple reports an error', async () => {
    const events: SttEvent[] = [];
    const stt = new FallbackSttAdapter(
      fakeAdapter('system', {failOnPush: 2}),
      async () => fakeAdapter('whisper'),
      () => {},
    );
    const session = stt.start({language: 'en', mode: 'dictation'}, e =>
      events.push(e),
    );
    session.push(chunk());
    session.push(chunk());
    session.push(chunk());
    expect((await session.finish()).text).toBe('whisper whisper whisper');
    expect(events.some(e => e.type === 'error')).toBe(false);
    expect(stt.usingBackup).toBe(true);
  });

  it('falls back when the first recogniser cannot load or finish', async () => {
    const stt = new FallbackSttAdapter(
      fakeAdapter('system', {failPrepare: true}),
      async () => fakeAdapter('whisper'),
      () => {},
    );
    await stt.prepare('en');
    expect(stt.id).toBe('whisper');

    const late = new FallbackSttAdapter(
      fakeAdapter('system', {failFinish: true}),
      async () => fakeAdapter('whisper'),
      () => {},
    );
    const session = late.start({language: 'en', mode: 'dictation'}, () => {});
    session.push(chunk());
    expect((await session.finish()).text).toBe('whisper');
  });

  it('reports one error when the backup fails too', async () => {
    const events: SttEvent[] = [];
    const stt = new FallbackSttAdapter(
      fakeAdapter('system', {failOnPush: 1}),
      async () => {
        throw new Error('no whisper model');
      },
      () => {},
    );
    const session = stt.start({language: 'en', mode: 'dictation'}, e =>
      events.push(e),
    );
    session.push(chunk());
    await expect(session.finish()).rejects.toThrow('no whisper model');
    expect(events.filter(e => e.type === 'error')).toHaveLength(1);
  });
});

describe('Apple stream binding', () => {
  function native(appendThrows: boolean) {
    const listeners: Record<string, (event: any) => void> = {};
    const started: string[] = [];
    return {
      listeners,
      started,
      module: wrapNativeTranscription(
        {
          getModelInfo: async () => ({}),
          prepare: async () => {},
          startStreamTranscription: async id => {
            started.push(id);
          },
          stopLiveTranscription: async () => {},
          onLiveTranscriptionResult: listener => {
            listeners.result = listener;
            return {remove() {}};
          },
          onLiveTranscriptionError: listener => {
            listeners.error = listener;
            return {remove() {}};
          },
        },
        () => () => {
          if (appendThrows) {
            throw new Error('noSession');
          }
        },
      ),
    };
  }

  it('turns a refused chunk into one error event instead of a throw', async () => {
    const {module} = native(true);
    const events: unknown[] = [];
    const task = createAppleSpeechBackend(module).start(
      {locale: 'en-US', punctuation: true},
      event => events.push(event),
    );
    expect(() => task.feed(new Int16Array(10))).not.toThrow();
    await flush();
    expect(() => task.feed(new Int16Array(10))).not.toThrow();
    expect(events).toEqual([{type: 'error', message: 'noSession'}]);
  });

  it('a throwing result handler does not escape the native listener', async () => {
    const {module, listeners, started} = native(false);
    createAppleSpeechBackend(module).start(
      {locale: 'en-US', punctuation: true},
      () => {
        throw new Error('render failed');
      },
    );
    await flush();
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    expect(() =>
      listeners.result({sessionId: started[0], text: 'x', isFinal: false}),
    ).not.toThrow();
    expect(warn).toHaveBeenCalled();
    warn.mockRestore();
  });
});
