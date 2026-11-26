/**
 * Engine dev screen. Debug builds only; see index.tsx.
 */
import React, {useEffect, useRef, useState} from 'react';
import {SafeAreaView, ScrollView, StyleSheet, Text} from 'react-native';

import {useChatSession} from '../../../hooks/useChatSession';
import {chatSessionStore, modelStore} from '../../../store';
import {assistant, derivedText, user} from '../../../utils/chat';
import {antichatNative} from '../downloads/native';
import {getEngine, installEngine} from '../install';
import {DevLog} from '../models/dev/devLog';
import {createDevRuntime} from '../models/dev/runner';
import {newestMessage} from '../prompt/postTurn';
import {getLastSentRequest} from '../prompt/seam';

import {runDevStep} from './steps';
import type {EngineDevConfig, EngineDevStep} from './types';

const sleep = (ms: number) =>
  new Promise<void>(resolve => setTimeout(resolve, ms));

async function waitFor(
  test: () => boolean,
  timeoutMs: number,
  what: string,
): Promise<void> {
  const end = Date.now() + timeoutMs;
  while (!test()) {
    if (Date.now() > end) {
      throw new Error(`timed out waiting for ${what}`);
    }
    await sleep(250);
  }
}

const systemTextOf = (messages: Array<{role: string; content?: unknown}>) => {
  const first = messages[0];
  return first?.role === 'system' && typeof first.content === 'string'
    ? first.content
    : '';
};

export function EngineDevScreen({config}: {config: EngineDevConfig}) {
  const [lines, setLines] = useState<string[]>([]);
  const messageInfo = useRef<{
    createdAt: number;
    id: string;
    sessionId: string;
  } | null>(null);
  const {handleSendPress} = useChatSession(messageInfo, user, assistant);
  const send = useRef(handleSendPress);
  send.current = handleSendPress;

  useEffect(() => {
    const log = new DevLog();
    const unsubscribe = log.subscribe(() => setLines(log.lines.slice(-40)));
    const results: unknown[] = [];
    const status = (more: Record<string, unknown>) =>
      log.status({mode: 'engine', results, ...more});

    const chat = async (step: Extract<EngineDevStep, {type: 'chat'}>) => {
      if (step.newChat) {
        chatSessionStore.resetActiveSession();
      }
      const before = getLastSentRequest()?.at ?? 0;
      const started = Date.now();
      const extra = step.attach?.length
        ? await runDevStep.attachments(step.attach, log)
        : {};
      await send.current({type: 'text', text: step.text, ...extra} as never);
      await waitFor(
        () => !chatSessionStore.isGenerating && !modelStore.isGenerationBusy,
        (step.timeoutSec ?? 600) * 1000,
        'the reply',
      );
      const session = chatSessionStore.sessions.find(
        s => s.id === chatSessionStore.activeSessionId,
      );
      const last = newestMessage(session?.messages) as
        | {type?: string; steps?: Array<{toolCalls?: any[]}>}
        | undefined;
      const sent = getLastSentRequest();
      const fresh = sent && sent.at > before ? sent : null;
      const memory = await antichatNative?.memoryInfo().catch(() => null);
      return {
        reply: last ? derivedText(last as never) : '',
        seconds: (Date.now() - started) / 1000,
        toolsCalled: (last?.steps ?? []).flatMap(s =>
          (s.toolCalls ?? []).map(call => String(call?.function?.name ?? '')),
        ),
        toolsOffered: fresh?.prepared.tools.map(tool => tool.function.name),
        systemChars: fresh ? systemTextOf(fresh.messages).length : null,
        system: fresh ? systemTextOf(fresh.messages) : null,
        lastUser: fresh
          ? String(
              [...fresh.messages].reverse().find(m => m.role === 'user')
                ?.content ?? '',
            ).slice(0, 6000)
          : null,
        meta: fresh?.prepared.meta,
        memoryInfo: memory,
      };
    };

    (async () => {
      const runtime = await createDevRuntime(config as never, log);
      const steps: string[] = [];
      const engine = await installEngine({
        modelRuntime: () => runtime,
        embeddings: !!config.embeddings,
        onStep: step => steps.push(step),
      });
      log.event('engine_installed', {steps, failed: engine.failed});
      const models = runtime.engine;
      if (config.model) {
        const id = config.model;
        if (models.stateOf(id).status === 'not_installed') {
          await models.download(id);
        }
        await waitFor(
          () =>
            ['ready', 'loaded', 'failed'].includes(models.stateOf(id).status),
          30 * 60_000,
          'the model files',
        );
        if (models.stateOf(id).status !== 'loaded') {
          await models.load(id);
        }
      } else {
        await models.getStarted();
      }
      await waitFor(
        () => {
          const active = models.activeModelId;
          return !!active && models.stateOf(active).status === 'loaded';
        },
        30 * 60_000,
        'a loaded model',
      );
      log.event('model_loaded', {
        model: models.activeModelId,
        deviceClass: models.deviceClass,
        state: models.stateOf(models.activeModelId!),
      });
      status({model: models.activeModelId});
      for (const [index, step] of (config.steps ?? []).entries()) {
        log.event('step_start', {index, step});
        try {
          const result =
            step.type === 'chat'
              ? await chat(step)
              : await runDevStep.other(step, getEngine()!, log);
          results.push({index, step, ok: true, result});
          log.event('step_done', {index, result});
        } catch (error) {
          results.push({index, step, ok: false, error: String(error)});
          log.event('step_failed', {index, error: String(error)});
        }
        status({});
      }
      status({finished: true});
      log.event('finished');
    })().catch(error => {
      log.event('fatal', {error: String(error)});
      status({finished: true, fatal: String(error)});
    });
    return unsubscribe;
  }, [config]);

  return (
    <SafeAreaView style={styles.root}>
      <ScrollView contentContainerStyle={styles.body}>
        <Text style={styles.title}>AntiChat engine dev run</Text>
        {lines.map((line, index) => (
          <Text key={index} style={styles.line} numberOfLines={3}>
            {line}
          </Text>
        ))}
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: '#101114'},
  body: {padding: 12},
  title: {color: '#FFFFFF', fontSize: 16, fontWeight: '600', marginBottom: 8},
  line: {color: '#B8BCC6', fontSize: 10, marginBottom: 4},
});
