import '../../../testing/setup';

import React from 'react';
import {act, fireEvent, render, screen} from '@testing-library/react-native';

import {FakeVoice} from '../../../contracts/fakes';
import {DemoVoice} from '../dev/DemoVoice';
import {DictationBar} from '../DictationBar';
import {asVoicePort} from '../port';
import {ReadAloudBar, ReadAloudButton} from '../ReadAloud';
import {DictationSettings} from '../DictationSettings';
import {DictationButton, DictationLayer, registerVoiceUi} from '../register';
import {formatBytes, formatElapsed} from '../strings';
import {VoiceModeDock} from '../VoiceModeDock';
import {VoicePicker} from '../VoicePicker';

jest.useFakeTimers();

const step = async (ms: number) => {
  await act(async () => {
    jest.advanceTimersByTime(ms);
  });
};

describe('DictationBar', () => {
  it('is absent while idle, shows live words, and hands the text over on confirm', async () => {
    const voice = new DemoVoice(100);
    const onText = jest.fn();
    render(<DictationBar voice={voice} onText={onText} />);
    expect(screen.queryByTestId('dictation-bar')).toBeNull();
    await act(async () => {
      await voice.startDictation();
    });
    expect(screen.getByTestId('dictation-hint')).toHaveTextContent(
      'Listening…',
    );
    await step(450);
    expect(screen.getByTestId('dictation-text')).toHaveTextContent(
      'What should I cook',
    );
    await act(async () => {
      fireEvent.press(screen.getByTestId('dictation-confirm'));
    });
    expect(onText).toHaveBeenCalledWith('What should I cook');
    expect(screen.queryByTestId('dictation-bar')).toBeNull();
  });

  it('cancel discards', async () => {
    const voice = new DemoVoice(100);
    const onText = jest.fn();
    render(<DictationBar voice={voice} onText={onText} />);
    await act(async () => {
      await voice.startDictation();
    });
    await step(300);
    fireEvent.press(screen.getByTestId('dictation-cancel'));
    expect(onText).not.toHaveBeenCalled();
    expect(voice.dictation.status).toBe('idle');
  });

  it('explains a failure', () => {
    const voice = new DemoVoice();
    voice.dictation = {
      status: 'failed',
      error: {code: 'permission_denied', retryable: false},
    };
    render(<DictationBar voice={voice} onText={() => {}} />);
    expect(screen.getByTestId('dictation-hint')).toHaveTextContent(
      /microphone access/,
    );
    expect(screen.queryByTestId('dictation-confirm')).toBeNull();
  });
});

describe('read aloud', () => {
  const text = 'One is first. Two is second. Three is third.';

  it('the answer button starts and stops; the bar controls playback', async () => {
    const voice = new DemoVoice(100);
    render(
      <>
        <ReadAloudButton voice={voice} messageId="m1" text={text} />
        <ReadAloudBar voice={voice} />
      </>,
    );
    expect(screen.queryByTestId('read-aloud-bar')).toBeNull();
    await act(async () => {
      fireEvent.press(screen.getByTestId('read-aloud-m1'));
    });
    expect(screen.getAllByLabelText('Stop reading')).toHaveLength(2);
    expect(screen.getByTestId('read-aloud-bar')).toBeTruthy();
    fireEvent.press(screen.getByTestId('read-aloud-toggle'));
    expect(voice.speech.status).toBe('paused');
    fireEvent.press(screen.getByTestId('read-aloud-next'));
    expect(voice.speech).toMatchObject({sentence: 1});
    fireEvent.press(screen.getByTestId('read-aloud-previous'));
    expect(voice.speech).toMatchObject({sentence: 0});
    fireEvent.press(screen.getByTestId('read-aloud-speed'));
    expect(voice.speech).toMatchObject({rate: 1.25});
    fireEvent.press(screen.getByTestId('read-aloud-toggle'));
    expect(voice.speech.status).toBe('speaking');
    await step(2000);
    expect(screen.queryByTestId('read-aloud-bar')).toBeNull();
  });

  it('close stops', async () => {
    const voice = new DemoVoice(100);
    render(<ReadAloudBar voice={voice} />);
    await act(async () => {
      await voice.speak('m1', text);
    });
    fireEvent.press(screen.getByTestId('read-aloud-close'));
    expect(voice.speech.status).toBe('idle');
  });
});

describe('VoiceModeDock', () => {
  it('shows each state on the orb, the live transcript, and the controls work', async () => {
    const voice = new DemoVoice(100);
    render(<VoiceModeDock voice={voice} />);
    expect(screen.queryByTestId('voice-dock')).toBeNull();
    await act(async () => {
      await voice.startVoiceMode();
    });
    expect(screen.getByTestId('voice-orb-starting')).toBeTruthy();
    await step(400);
    expect(screen.getByTestId('voice-orb-listening')).toBeTruthy();
    expect(screen.getByTestId('voice-status')).toHaveTextContent(
      'Tell me something',
    );
    await step(400);
    expect(screen.getByTestId('voice-orb-thinking')).toBeTruthy();
    await step(500);
    expect(screen.getByTestId('voice-orb-speaking')).toBeTruthy();
    expect(screen.getByTestId('voice-status')).toHaveTextContent(
      'Tap the orb to interrupt',
    );
    fireEvent.press(screen.getByTestId('voice-orb'));
    expect(voice.voiceMode.status).toBe('listening');
    fireEvent.press(screen.getByTestId('voice-mute'));
    expect(screen.getByTestId('voice-orb-muted')).toBeTruthy();
    fireEvent.press(screen.getByTestId('voice-mute'));
    act(() => voice.pauseForCall());
    expect(screen.getByTestId('voice-orb-paused')).toBeTruthy();
    await act(async () => {
      fireEvent.press(screen.getByTestId('voice-orb'));
    });
    expect(voice.voiceMode.status).toBe('listening');
    fireEvent.press(screen.getByTestId('voice-end'));
    expect(screen.queryByTestId('voice-dock')).toBeNull();
  });
});

describe('VoicePicker', () => {
  it('lists voices with size or status, downloads on choice and plays a sample', async () => {
    const voice = new DemoVoice(100);
    render(<VoicePicker voice={voice} />);
    expect(screen.getByText('Recommended')).toBeTruthy();
    expect(screen.getByText('Download · 346 MB')).toBeTruthy();
    fireEvent.press(screen.getByTestId('voice-kokoro:af_heart'));
    await step(150);
    expect(screen.getByText(/Downloading \d+%/)).toBeTruthy();
    for (let i = 0; i < 6; i++) {
      await step(100);
    }
    expect(voice.voiceId).toBe('kokoro:af_heart');
    expect(voice.pronounced).toHaveLength(1);
    expect(screen.queryByText('Download · 346 MB')).toBeNull();
  });

  it('switches write settings', () => {
    const voice = new DemoVoice();
    render(<VoicePicker voice={voice} />);
    fireEvent.press(screen.getByLabelText('Interrupt by speaking'));
    expect(voice.settings.bargeIn).toBe(false);
  });
});

describe('registration (version 1: dictation only)', () => {
  it('the mic button drives the layer and dictated text reaches the host', async () => {
    const voice = new DemoVoice(100);
    const insertText = jest.fn();
    const unregister = registerVoiceUi({insertText}, voice);
    render(
      <>
        <DictationLayer voice={voice} />
        <DictationButton voice={voice} />
      </>,
    );
    expect(screen.queryByTestId('dictation-bar')).toBeNull();
    await act(async () => {
      fireEvent.press(screen.getByTestId('composer-dictate'));
    });
    expect(screen.getByTestId('composer-dictate')).toBeDisabled();
    await step(450);
    await act(async () => {
      fireEvent.press(screen.getByTestId('dictation-confirm'));
    });
    expect(insertText).toHaveBeenCalledWith('What should I cook');
    expect(screen.getByTestId('composer-dictate')).toBeEnabled();
    unregister();
  });

  it('a refused microphone points to Settings; other failures offer a retry', async () => {
    const voice = new DemoVoice(100);
    voice.dictation = {
      status: 'failed',
      error: {code: 'permission_denied', retryable: false},
    };
    const view = render(<DictationBar voice={voice} onText={() => {}} />);
    expect(screen.getByTestId('dictation-open-settings')).toBeTruthy();
    expect(screen.queryByTestId('dictation-retry')).toBeNull();
    view.unmount();

    voice.dictation = {
      status: 'failed',
      error: {code: 'model_missing', retryable: false},
    };
    render(<DictationBar voice={voice} onText={() => {}} />);
    expect(screen.getByTestId('dictation-hint')).toHaveTextContent(
      /speech model/,
    );
    await act(async () => {
      fireEvent.press(screen.getByTestId('dictation-retry'));
    });
    expect(voice.dictation.status).toBe('listening');
  });

  it('the language and punctuation rows write settings', () => {
    const voice = new DemoVoice();
    render(<DictationSettings voice={voice} />);
    fireEvent.press(screen.getByTestId('dictation-language-de'));
    expect(voice.settings.language).toBe('de');
    fireEvent(
      screen.getByLabelText('Punctuation in dictation'),
      'valueChange',
      false,
    );
    expect(voice.settings.punctuation).toBe(false);
  });
});

describe('port lift and formatting', () => {
  it('lifts the M1 contract port to the engine shape', async () => {
    const fake = new FakeVoice(50);
    const voice = asVoicePort(fake);
    expect(asVoicePort(fake)).toBe(voice);
    expect(asVoicePort(voice)).toBe(voice);
    expect(voice.voices[0]).toMatchObject({installed: true, recommended: true});
    await voice.startDictation();
    jest.advanceTimersByTime(120);
    expect(voice.dictation).toMatchObject({
      status: 'listening',
      partial: 'What should',
      stableLength: 11,
    });
    voice.cancelDictation();
    await voice.speak('m1', 'Hi.');
    voice.setSpeechRate(1.5);
    expect(voice.speech).toMatchObject({
      status: 'speaking',
      rate: 1.5,
      sentenceCount: 1,
    });
    await voice.startVoiceMode(null);
    expect(voice.voiceMode).toMatchObject({status: 'listening', partial: ''});
  });

  it('formats sizes and time', () => {
    expect(formatBytes(57 * 1024 * 1024)).toBe('60 MB');
    expect(formatBytes(1_500_000_000)).toBe('1.5 GB');
    expect(formatElapsed(75_400)).toBe('1:15');
  });
});
