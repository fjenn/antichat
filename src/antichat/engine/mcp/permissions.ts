/**
 * Confirmation before write actions.
 *
 * Every connector action has a permission key (`composio:GMAIL_SEND_EMAIL`,
 * `mcp:<server>:<tool>`). Reads run. A write waits for the user: the engine
 * queues an approval request, the UI shows it (Allow once / Always allow /
 * Don't allow) and answers it. "Always allow" stores a policy for that one
 * action. The model never sees or answers a request.
 */
export type Policy = 'always' | 'ask' | 'block';
export type ApprovalAnswer = 'once' | 'always' | 'deny';

export interface ApprovalRequest {
  id: string;
  key: string;
  /** "Gmail" */
  app: string;
  /** "Send email" */
  action: string;
  /** What will be sent, for the user to review. */
  arguments: Record<string, unknown>;
  createdAt: number;
}

export interface KeyValueStore {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

const STORAGE_KEY = 'antichat.connectors.permissions.v1';
/** An unanswered request is denied after this long. */
export const APPROVAL_TIMEOUT_MS = 5 * 60_000;

export class Permissions {
  private policies: Record<string, Policy> = {};
  private loaded: Promise<void> | null = null;
  private pending: Array<{
    request: ApprovalRequest;
    resolve: (answer: ApprovalAnswer) => void;
  }> = [];
  private readonly listeners = new Set<() => void>();
  private counter = 0;

  constructor(private readonly storage?: KeyValueStore) {}

  load(): Promise<void> {
    this.loaded ??= (async () => {
      try {
        const raw = await this.storage?.getItem(STORAGE_KEY);
        if (raw) {
          this.policies = JSON.parse(raw);
        }
      } catch {
        this.policies = {};
      }
    })();
    return this.loaded;
  }

  policy(key: string): Policy | undefined {
    return this.policies[key];
  }

  async setPolicy(key: string, policy: Policy | null): Promise<void> {
    if (policy) {
      this.policies[key] = policy;
    } else {
      delete this.policies[key];
    }
    await this.storage
      ?.setItem(STORAGE_KEY, JSON.stringify(this.policies))
      .catch(() => {});
  }

  /** Drop every stored policy whose key starts with `prefix`. */
  async forget(prefix: string): Promise<void> {
    for (const key of Object.keys(this.policies)) {
      if (key.startsWith(prefix)) {
        delete this.policies[key];
      }
    }
    await this.storage
      ?.setItem(STORAGE_KEY, JSON.stringify(this.policies))
      .catch(() => {});
  }

  /** Requests waiting for the user, oldest first. */
  requests(): ApprovalRequest[] {
    return this.pending.map(entry => entry.request);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private notify(): void {
    this.listeners.forEach(listener => listener());
  }

  /**
   * May this action run? Reads: yes. Writes: by stored policy, else the user
   * is asked. Resolves false when denied, blocked, timed out or cancelled.
   */
  async allow(
    action: {
      key: string;
      app: string;
      action: string;
      arguments: Record<string, unknown>;
      write: boolean;
    },
    signal?: AbortSignal,
  ): Promise<boolean> {
    await this.load();
    const stored = this.policies[action.key];
    if (stored === 'block') {
      return false;
    }
    if (!action.write || stored === 'always') {
      return true;
    }
    const request: ApprovalRequest = {
      id: `approval-${Date.now().toString(36)}-${this.counter++}`,
      key: action.key,
      app: action.app,
      action: action.action,
      arguments: action.arguments,
      createdAt: Date.now(),
    };
    const answer = await new Promise<ApprovalAnswer>(resolve => {
      const finish = (value: ApprovalAnswer) => {
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        const at = this.pending.findIndex(entry => entry.request === request);
        if (at !== -1) {
          this.pending.splice(at, 1);
          this.notify();
        }
        resolve(value);
      };
      const onAbort = () => finish('deny');
      const timer = setTimeout(onAbort, APPROVAL_TIMEOUT_MS);
      signal?.addEventListener('abort', onAbort);
      this.pending.push({request, resolve: finish});
      this.notify();
      if (signal?.aborted) {
        onAbort();
      }
    });
    if (answer === 'always') {
      await this.setPolicy(action.key, 'always');
    }
    return answer !== 'deny';
  }

  /** The UI's answer to a request. */
  answer(id: string, answer: ApprovalAnswer): void {
    this.pending.find(entry => entry.request.id === id)?.resolve(answer);
  }
}

export const DENIED_RESULT =
  'The user did not allow this action. Do not try it again; tell them it was not done.';
