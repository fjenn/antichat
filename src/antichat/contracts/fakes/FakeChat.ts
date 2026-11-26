import type {
  ChatEvent,
  ChatMessageView,
  ChatPort,
  GenerationPhase,
  MessageFeedback,
  SendInput,
  SendOptions,
  SendResult,
  Starter,
} from '../chat';
import {Emitter, type PortError, type Unsubscribe} from '../common';
import {
  FAKE_REASONING,
  fakeAnswerFor,
  fakeTitleFor,
  fakeTokens,
} from './answers';
import type {FakeConversations} from './FakeConversations';

export interface FakeChatOptions {
  /** Speed of the fake model. On-device models run at roughly 15 to 60. */
  tokensPerSecond?: number;
  /** Wait before the first token, as if the prompt were being read. */
  firstTokenMs?: number;
  now?: () => number;
}

interface Run {
  messageId: string;
  timer?: ReturnType<typeof setTimeout>;
  phase: GenerationPhase;
}

const STARTERS: Starter[] = [
  {
    id: 'learn-explain',
    category: 'learn',
    label: 'Explain a tricky idea simply',
    prompt: 'Explain how transformers work, simply.',
  },
  {
    id: 'write-note',
    category: 'write',
    label: 'Write a birthday message',
    prompt: 'Write a short birthday message for my mum.',
  },
  {
    id: 'code-debug',
    category: 'code',
    label: 'Find the bug in a test',
    prompt: 'My Jest test fails around midnight. What could be wrong?',
  },
  {
    id: 'plan-week',
    category: 'plan',
    label: 'Plan my week',
    prompt: 'Help me plan a calm, productive week.',
  },
];

/**
 * A chat that behaves like the real one: pending, an optional thinking
 * phase, then markdown arriving token by token; stop, regenerate, edit and
 * versions work. Nothing is persisted.
 */
export class FakeChat extends Emitter implements ChatPort {
  private readonly threads = new Map<string, ChatMessageView[]>();
  /** Every version of an answer, by the id of the first version. */
  private readonly versions = new Map<string, ChatMessageView[]>();
  private readonly runs = new Map<string, Run>();
  private readonly eventListeners = new Map<
    string,
    Set<(event: ChatEvent) => void>
  >();
  private readonly suggestions = new Map<string, readonly string[]>();
  private nextId = 1;
  private failure: PortError | null = null;
  private scripted: string | null = null;
  private tokensPerSecond: number;
  private readonly firstTokenMs: number;
  private readonly now: () => number;

  constructor(
    private readonly conversations: FakeConversations,
    options: FakeChatOptions = {},
  ) {
    super();
    this.tokensPerSecond = options.tokensPerSecond ?? 40;
    this.firstTokenMs = options.firstTokenMs ?? 500;
    this.now = options.now ?? Date.now;
  }

  messages(conversationId: string): readonly ChatMessageView[] {
    return this.threads.get(conversationId) ?? EMPTY;
  }

  phase(conversationId: string): GenerationPhase | null {
    return this.runs.get(conversationId)?.phase ?? null;
  }

  isGenerating(conversationId: string): boolean {
    return this.runs.has(conversationId);
  }

  listen(
    conversationId: string,
    listener: (event: ChatEvent) => void,
  ): Unsubscribe {
    const set = this.eventListeners.get(conversationId) ?? new Set();
    set.add(listener);
    this.eventListeners.set(conversationId, set);
    return () => {
      set.delete(listener);
    };
  }

  async send(
    conversationId: string | null,
    input: SendInput,
  ): Promise<SendResult> {
    const id = conversationId ?? (await this.conversations.create()).id;
    // Sending while an answer runs interrupts it; the partial text is kept.
    this.stop(id);
    this.suggestions.delete(id);
    this.conversations.touch(id, fakeTitleFor(input.text));
    const user = this.add(id, {
      role: 'user',
      text: input.text,
      status: 'complete',
      attachments: input.attachments,
    });
    const assistant = this.startAnswer(id, input.text, input);
    return {
      conversationId: id,
      userMessageId: user.id,
      assistantMessageId: assistant.id,
    };
  }

  stop(conversationId: string): void {
    const run = this.runs.get(conversationId);
    if (run) {
      this.finish(conversationId, run, 'stopped');
    }
  }

  async regenerate(
    conversationId: string,
    assistantMessageId: string,
    options: SendOptions = {},
  ): Promise<SendResult> {
    this.stop(conversationId);
    this.suggestions.delete(conversationId);
    const thread = [...this.messages(conversationId)];
    const at = thread.findIndex(message => message.id === assistantMessageId);
    const user = thread[at - 1];
    if (at < 0 || !user) {
      throw new Error(`No answer ${assistantMessageId} to regenerate`);
    }
    const old = thread[at];
    const rootId = this.rootOf(old.id);
    this.threads.set(conversationId, thread.slice(0, at));
    this.dispatch(conversationId, {type: 'message_removed', messageId: old.id});
    const assistant = this.startAnswer(
      conversationId,
      user.text,
      options,
      rootId,
      old,
    );
    return {
      conversationId,
      userMessageId: user.id,
      assistantMessageId: assistant.id,
    };
  }

  async edit(
    conversationId: string,
    userMessageId: string,
    input: SendInput,
  ): Promise<SendResult> {
    this.stop(conversationId);
    const thread = this.messages(conversationId);
    const at = thread.findIndex(message => message.id === userMessageId);
    if (at < 0) {
      throw new Error(`No message ${userMessageId} to edit`);
    }
    thread.slice(at).forEach(message =>
      this.dispatch(conversationId, {
        type: 'message_removed',
        messageId: message.id,
      }),
    );
    this.threads.set(conversationId, thread.slice(0, at));
    return this.send(conversationId, input);
  }

  async switchVersion(
    conversationId: string,
    messageId: string,
    index: number,
  ): Promise<void> {
    const all = this.versions.get(this.rootOf(messageId));
    const target = all?.[index];
    if (!all || !target) {
      return;
    }
    this.stop(conversationId);
    const next = {...target, version: {index, count: all.length}};
    this.threads.set(
      conversationId,
      this.messages(conversationId).map(message =>
        this.rootOf(message.id) === this.rootOf(messageId) ? next : message,
      ),
    );
    this.dispatch(conversationId, {type: 'message_updated', message: next});
    this.emit();
  }

  followUps(conversationId: string): readonly string[] {
    return this.suggestions.get(conversationId) ?? NO_FOLLOW_UPS;
  }

  async setFeedback(
    conversationId: string,
    messageId: string,
    feedback: MessageFeedback | null,
  ): Promise<void> {
    const updated = this.update(conversationId, messageId, {
      feedback: feedback ?? undefined,
    });
    if (updated) {
      this.dispatch(conversationId, {
        type: 'message_updated',
        message: updated,
      });
      this.emit();
    }
  }

  starters(count = 4): readonly Starter[] {
    return STARTERS.slice(0, count);
  }

  /** Test and demo control: the next answer fails with this error. */
  failNext(error: PortError): void {
    this.failure = error;
  }

  /** Test and demo control: the speed of the fake model from now on. */
  setRate(tokensPerSecond: number): void {
    this.tokensPerSecond = tokensPerSecond;
  }

  /** Test and demo control: every following answer is this text (null: off). */
  script(answer: string | null): void {
    this.scripted = answer;
  }

  /** Test and demo control: put a finished exchange into a chat. */
  seed(conversationId: string, prompt: string, answer?: string): void {
    this.add(conversationId, {role: 'user', text: prompt, status: 'complete'});
    this.add(conversationId, {
      role: 'assistant',
      text: answer ?? fakeAnswerFor(prompt),
      status: 'complete',
      modelId: 'fake-small',
    });
  }

  private readonly roots = new Map<string, string>();

  private rootOf(messageId: string): string {
    return this.roots.get(messageId) ?? messageId;
  }

  private startAnswer(
    conversationId: string,
    prompt: string,
    options: SendOptions,
    rootId?: string,
    previous?: ChatMessageView,
  ): ChatMessageView {
    const assistant = this.add(conversationId, {
      role: 'assistant',
      text: '',
      status: 'pending',
      modelId: options.modelId ?? 'fake-small',
    });
    const root = rootId ?? assistant.id;
    this.roots.set(assistant.id, root);
    const all = this.versions.get(root) ?? (previous ? [previous] : []);
    all.push(assistant);
    this.versions.set(root, all);

    const run: Run = {
      messageId: assistant.id,
      phase: options.thinking ? 'thinking' : 'writing',
    };
    this.runs.set(conversationId, run);
    this.dispatch(conversationId, {
      type: 'phase',
      messageId: assistant.id,
      phase: run.phase,
    });
    this.emit();

    const failure = this.failure;
    this.failure = null;
    const reasoning = options.thinking ? fakeTokens(FAKE_REASONING) : [];
    const answer = fakeTokens(this.scripted ?? fakeAnswerFor(prompt));
    const startedAt = this.now();
    let step = 0;

    // One step: a thinking token, an answer token, or the end. Returns false
    // when the run is over.
    const advance = (): boolean => {
      if (failure && step >= 3) {
        this.update(conversationId, assistant.id, {error: failure});
        this.finish(conversationId, run, 'error');
        return false;
      }
      if (step < reasoning.length) {
        const delta = reasoning[step];
        this.update(conversationId, assistant.id, message => ({
          status: 'streaming',
          reasoning: {text: (message.reasoning?.text ?? '') + delta},
        }));
        this.dispatch(conversationId, {
          type: 'reasoning_delta',
          messageId: assistant.id,
          delta,
        });
      } else if (step - reasoning.length < answer.length) {
        if (step === reasoning.length && reasoning.length > 0) {
          run.phase = 'writing';
          this.update(conversationId, assistant.id, message => ({
            reasoning: {
              text: message.reasoning?.text ?? '',
              durationMs: this.now() - startedAt,
            },
          }));
          this.dispatch(conversationId, {
            type: 'phase',
            messageId: assistant.id,
            phase: 'writing',
          });
        }
        const delta = answer[step - reasoning.length];
        this.update(conversationId, assistant.id, message => ({
          status: 'streaming',
          text: message.text + delta,
        }));
        this.dispatch(conversationId, {
          type: 'text_delta',
          messageId: assistant.id,
          delta,
        });
      } else {
        this.finish(conversationId, run, 'complete');
        return false;
      }
      step += 1;
      return true;
    };

    // Clock-driven, so a late timer emits the tokens it missed in a burst,
    // the way a model does after the JS thread was busy.
    let firstAt = 0;
    const tick = () => {
      if (this.runs.get(conversationId) !== run) {
        return;
      }
      firstAt = firstAt || this.now();
      const due =
        Math.floor(((this.now() - firstAt) / 1000) * this.tokensPerSecond) + 1;
      while (step < due) {
        if (!advance()) {
          return;
        }
      }
      this.emit();
      run.timer = setTimeout(tick, 1000 / this.tokensPerSecond);
    };
    run.timer = setTimeout(tick, this.firstTokenMs);
    return assistant;
  }

  private finish(
    conversationId: string,
    run: Run,
    status: 'complete' | 'stopped' | 'error',
  ): void {
    clearTimeout(run.timer);
    this.runs.delete(conversationId);
    const all = this.versions.get(this.rootOf(run.messageId)) ?? [];
    const updated = this.update(conversationId, run.messageId, {
      status,
      version:
        all.length > 1 ? {index: all.length - 1, count: all.length} : undefined,
    });
    if (updated) {
      all[all.length - 1] = updated;
    }
    if (status === 'complete') {
      this.suggestions.set(conversationId, FAKE_FOLLOW_UPS);
    }
    this.dispatch(conversationId, {
      type: 'finished',
      messageId: run.messageId,
      status,
    });
    this.emit();
  }

  private add(
    conversationId: string,
    fields: Pick<ChatMessageView, 'role' | 'text' | 'status'> &
      Partial<ChatMessageView>,
  ): ChatMessageView {
    const message: ChatMessageView = {
      id: `m${this.nextId++}`,
      conversationId,
      createdAt: this.now(),
      ...fields,
    };
    this.threads.set(conversationId, [
      ...this.messages(conversationId),
      message,
    ]);
    this.dispatch(conversationId, {type: 'message_added', message});
    this.emit();
    return message;
  }

  private update(
    conversationId: string,
    messageId: string,
    change:
      | Partial<ChatMessageView>
      | ((message: ChatMessageView) => Partial<ChatMessageView>),
  ): ChatMessageView | undefined {
    let result: ChatMessageView | undefined;
    this.threads.set(
      conversationId,
      this.messages(conversationId).map(message => {
        if (message.id !== messageId) {
          return message;
        }
        result = {
          ...message,
          ...(typeof change === 'function' ? change(message) : change),
        };
        return result;
      }),
    );
    return result;
  }

  private dispatch(conversationId: string, event: ChatEvent): void {
    this.eventListeners.get(conversationId)?.forEach(listener => {
      listener(event);
    });
  }
}

const EMPTY: readonly ChatMessageView[] = Object.freeze([]);
const NO_FOLLOW_UPS: readonly string[] = Object.freeze([]);
const FAKE_FOLLOW_UPS: readonly string[] = Object.freeze([
  'Show me a shorter version',
  'Give me a real example',
  'What should I read next?',
]);
