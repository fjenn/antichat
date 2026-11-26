/**
 * whisper.cpp on the Mac as a `WhisperBackend` (Node only): the same engine
 * and the same model file (ggml-base-q8_0.bin) that whisper.rn runs on the
 * phone, so the recogniser pipeline can be scored on real audio from Jest.
 *
 * The decode is synchronous, which also lets it run under the virtual clock.
 */
import {execFileSync} from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

import {encodeWav} from '../../audio/wav';
import type {WhisperBackend} from '../../stt/whisperAdapter';

export const HOST_WHISPER_MODEL =
  process.env.VOICE_WHISPER_MODEL ??
  path.resolve(__dirname, '../../../../../../models/voice/ggml-base-q8_0.bin');

export function hostWhisperAvailable(): boolean {
  if (!fs.existsSync(HOST_WHISPER_MODEL)) {
    return false;
  }
  try {
    execFileSync('whisper-cli', ['--help'], {stdio: 'ignore'});
    return true;
  } catch {
    return false;
  }
}

export class WhisperCliBackend implements WhisperBackend {
  decodes = 0;
  decodeWallMs = 0;
  audioMs = 0;
  private readonly dir = fs.mkdtempSync(path.join(os.tmpdir(), 'voice-wer-'));

  async transcribe(
    pcm: Int16Array,
    options: {language?: string; prompt?: string},
  ): Promise<{text: string; language: string}> {
    const base = path.join(this.dir, `a${this.decodes++}`);
    fs.writeFileSync(`${base}.wav`, encodeWav(pcm));
    const started = Date.now();
    execFileSync(
      'whisper-cli',
      [
        '-m',
        HOST_WHISPER_MODEL,
        '-f',
        `${base}.wav`,
        '-l',
        options.language ?? 'auto',
        '-nt',
        '-np',
        '-oj',
        '-of',
        base,
        ...(options.prompt ? ['--prompt', options.prompt] : []),
      ],
      {stdio: 'ignore'},
    );
    this.decodeWallMs += Date.now() - started;
    this.audioMs += pcm.length / 16;
    const json = JSON.parse(fs.readFileSync(`${base}.json`, 'utf8'));
    fs.rmSync(`${base}.wav`);
    fs.rmSync(`${base}.json`);
    return {
      text: (json.transcription as {text: string}[]).map(t => t.text).join(''),
      language: json.result?.language ?? '',
    };
  }

  async cancel(): Promise<void> {}

  dispose(): void {
    fs.rmSync(this.dir, {recursive: true, force: true});
  }
}
