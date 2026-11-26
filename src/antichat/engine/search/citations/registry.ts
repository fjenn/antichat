/**
 * Source registry: one numbered list of sources per answer. Every web step
 * of a turn (forced search, model-called search, page reads) appends to the
 * same registry, so `[3]` means one thing for the whole answer and for the
 * Sources sheet. A URL that comes back twice keeps its first number.
 */
import type {ToolImage, ToolSource} from '../../tools/types';
import {hostOf, normalizeUrl} from '../html';

export interface RegisteredSource extends ToolSource {
  /** 1-based number the model cites. */
  n: number;
  /** Favicon URL for the pill; omitted when favicons are switched off. */
  favicon?: string;
}

export interface SourceRegistrySnapshot {
  sources: RegisteredSource[];
  images: ToolImage[];
  queries: string[];
}

export class SourceRegistry {
  private readonly list: RegisteredSource[] = [];
  private readonly byKey = new Map<string, RegisteredSource>();
  private readonly imageList: ToolImage[] = [];
  private readonly queryList: string[] = [];

  /** Add sources; returns them with their numbers (existing ones reused). */
  add(sources: ToolSource[]): RegisteredSource[] {
    return sources.map(source => {
      const key = normalizeUrl(source.url);
      const existing = this.byKey.get(key);
      if (existing) {
        // A later read of the same page upgrades snippet-only evidence.
        if (source.fetched && source.evidence) {
          existing.fetched = true;
          existing.evidence = existing.evidence?.includes(source.evidence)
            ? existing.evidence
            : [existing.evidence, source.evidence].filter(Boolean).join('\n');
        }
        existing.publishedAt ??= source.publishedAt;
        return existing;
      }
      const registered: RegisteredSource = {
        ...source,
        site: source.site || hostOf(source.url),
        n: this.list.length + 1,
      };
      this.list.push(registered);
      this.byKey.set(key, registered);
      return registered;
    });
  }

  addImages(images: ToolImage[]): void {
    for (const image of images) {
      if (!this.imageList.some(existing => existing.url === image.url)) {
        this.imageList.push(image);
      }
    }
  }

  addQuery(query: string): void {
    if (query && !this.queryList.includes(query)) {
      this.queryList.push(query);
    }
  }

  get sources(): RegisteredSource[] {
    return this.list;
  }

  get images(): ToolImage[] {
    return this.imageList;
  }

  get size(): number {
    return this.list.length;
  }

  get(n: number): RegisteredSource | undefined {
    return this.list[n - 1];
  }

  /** `n → text the model saw for that source` (chunks, else the snippet). */
  evidence(): Record<number, string> {
    const out: Record<number, string> = {};
    for (const source of this.list) {
      const text = source.evidence ?? source.snippet ?? '';
      if (text) {
        out[source.n] = `${source.title}\n${text}`;
      }
    }
    return out;
  }

  snapshot(): SourceRegistrySnapshot {
    return {
      sources: this.list.map(source => ({...source})),
      images: [...this.imageList],
      queries: [...this.queryList],
    };
  }
}

const registries = new Map<string, SourceRegistry>();
const MAX_TURNS = 16;

/** The registry of a turn, created on first use. */
export function registryForTurn(turnId: string): SourceRegistry {
  let registry = registries.get(turnId);
  if (!registry) {
    registry = new SourceRegistry();
    registries.set(turnId, registry);
    while (registries.size > MAX_TURNS) {
      registries.delete(registries.keys().next().value as string);
    }
  }
  return registry;
}

export function peekRegistry(turnId: string): SourceRegistry | undefined {
  return registries.get(turnId);
}

export function clearRegistry(turnId: string): void {
  registries.delete(turnId);
}

export function resetRegistries(): void {
  registries.clear();
}

/** DuckDuckGo's icon service; leaks the host, so it is a setting. */
export const faviconUrl = (site: string): string =>
  `https://icons.duckduckgo.com/ip3/${site}.ico`;
