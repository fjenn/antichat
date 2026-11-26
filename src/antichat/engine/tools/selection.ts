/**
 * Active-tool selection (correction 4 of the gap analysis: upstream switches
 * tools on per pal; AntiChat decides per chat and per turn).
 *
 * `selectTools` is the pure decision; `createToolSelectionProvider` plugs it
 * into the D2 seam. What a request ends up with:
 *
 *   - tools whose chip is on for the chat
 *   - deferred tools `search_tools` has switched on for the chat
 *   - the pal's own tools (upstream), unless an AntiChat tool supersedes them
 *   - the always-on set
 *   - `search_tools`, when usable deferred tools remain
 *   all under the model's tool-count and schema-token caps, and without any
 *   online tool while the device is offline.
 *
 * The set is a function of chips, activations, connectivity and the model
 * only — never of the message — so it stays byte-stable from turn to turn
 * and the KV cache survives (all three template families render the tool
 * list before the history). The per-message search gate therefore does not
 * remove tools: "no tool needed" becomes `tool_choice: none`, and "needs the
 * web" becomes a search the harness runs itself.
 */
import {messageText} from '../context/tokenCounter';
import {TOOL_USE_CLAUSE} from '../prompt/systemPrompt';
import type {
  ChatMessage,
  Contribution,
  RequestContext,
  RequestDraft,
  RequestProvider,
  ToolDefinition,
} from '../prompt/types';
import {decideSearch, type SearchVerdict} from '../search/decision';
import {knowledgeCutoffFor} from '../search/freshTerms';
import {CITE_SYSTEM_RULE} from '../search/resultsBlock';
import {getSearchService} from '../search/service';
import {RELATIVE_DATE, upcomingDatesLine} from './builtin/datetime';
import {SEARCH_TOOLS_NAME, toolCatalog, type ToolCatalog} from './catalog';
import {
  activatedTools,
  activeChips,
  consumeOneShotChips,
  type ChipId,
} from './chips';
import {hasForgetCue, hasMemoryCue} from '../memory/extraction';
import {OFFLINE_CHAT_NOTE, allowedOffline} from '../offline';
import {isLocationAllowed} from './builtin/location';
import {OFFLINE_NOTE, isOnline} from './connectivity';

const LOCATION_TOOL = 'get_location';
import {executeGuarded} from './execute';
import {LOOP_POLICY, LoopGuard} from './loopGuard';
import {RepairState} from './repair';
import {toolCapsFor, type ToolCaps} from './toolCaps';
import {beginTurn} from './turnState';
import {toToolDefinition, type AntichatTool} from './types';

export const TOOL_SELECTION_PROVIDER_ID = 'antichat.tools';

/** Upstream talents an AntiChat tool replaces. */
export const SUPERSEDES: Record<string, string> = {
  calculate: 'calculator',
  datetime: 'date_time',
};

export interface SelectionInput {
  /** Catalogue tools in registration order. */
  catalog: AntichatTool[];
  /** Tools already on the request (the pal's talents). */
  baseTools?: ToolDefinition[];
  chips?: ChipId[];
  /** Deferred tools switched on for the chat, oldest first. */
  activated?: string[];
  online: boolean;
  caps: ToolCaps;
  /**
   * The user's message. Tools whose keywords or triggers it names take a
   * seat right behind the two web tools, whatever their tier (the Mac
   * evaluation's "2 pinned + retrieved by keyword").
   */
  userText?: string;
}

export interface Selection {
  tools: ToolDefinition[];
  names: string[];
  /** Online tools withheld because the device is offline. */
  offline: string[];
  /** Tools that did not fit under the cap. */
  overCap: string[];
  /** Upstream tools replaced by an AntiChat tool. */
  superseded: string[];
}

const schemaTokens = (tool: ToolDefinition): number =>
  Math.ceil(JSON.stringify(tool.function).length / 3.6);

/** The pure selection. */
export function selectTools(input: SelectionInput): Selection {
  const {caps} = input;
  const empty: Selection = {
    tools: [],
    names: [],
    offline: [],
    overCap: [],
    superseded: [],
  };
  const base = input.baseTools ?? [];
  if (caps.maxTools <= 0) {
    return {
      ...empty,
      overCap: [
        ...base.map(tool => tool.function.name),
        ...input.catalog.map(tool => tool.name),
      ],
    };
  }
  const chips = new Set(input.chips ?? []);
  const activated = input.activated ?? [];
  const byName = new Map(input.catalog.map(tool => [tool.name, tool]));
  const usable = (tool: AntichatTool) => input.online || tool.kind !== 'online';
  const offline = input.catalog
    .filter(
      tool =>
        !usable(tool) &&
        (tool.tier === 'always' ||
          (tool.chip && chips.has(tool.chip)) ||
          activated.includes(tool.name)),
    )
    .map(tool => tool.name);

  const superseded: string[] = [];
  const baseKept = base.filter(tool => {
    const name = tool.function.name;
    const replacement = SUPERSEDES[name];
    if ((replacement && byName.has(replacement)) || byName.has(name)) {
      if (!byName.has(name)) {
        superseded.push(name);
      }
      return false;
    }
    return true;
  });

  // Candidates in priority order (who keeps a seat under the cap).
  const wanted: string[] = [];
  const want = (name: string) => {
    if (!wanted.includes(name)) {
      wanted.push(name);
    }
  };
  input.catalog
    .filter(tool => tool.chip && chips.has(tool.chip) && usable(tool))
    .forEach(tool => want(tool.name));
  [...activated]
    .reverse()
    .filter(name => byName.has(name) && usable(byName.get(name)!))
    .forEach(want);
  // A pal's own tool list is an explicit choice: it comes before defaults.
  base
    .filter(
      tool =>
        byName.has(tool.function.name) &&
        usable(byName.get(tool.function.name)!),
    )
    .forEach(tool => want(tool.function.name));
  baseKept.forEach(tool => want(tool.function.name));
  const matched = input.userText
    ? matchingTools(input.userText, input.catalog.filter(usable))
    : [];
  if (matched.length > 0) {
    // The pinned pair first, then what the message asks for.
    PINNED_WEB.filter(
      name => byName.has(name) && usable(byName.get(name)!),
    ).forEach(want);
    matched.slice(0, MAX_MATCHED).forEach(tool => want(tool.name));
  }
  input.catalog
    .filter(
      tool =>
        tool.tier === 'always' &&
        tool.name !== SEARCH_TOOLS_NAME &&
        usable(tool),
    )
    .forEach(tool => want(tool.name));

  const hasDeferred =
    caps.toolSearch &&
    byName.has(SEARCH_TOOLS_NAME) &&
    input.catalog.some(
      tool =>
        tool.tier === 'deferred' &&
        usable(tool) &&
        !activated.includes(tool.name),
    );
  const seats = caps.maxTools - (hasDeferred ? 1 : 0);

  const definitionOf = (name: string): ToolDefinition | undefined => {
    const tool = byName.get(name);
    if (tool) {
      return toToolDefinition(tool);
    }
    return baseKept.find(candidate => candidate.function.name === name);
  };

  const chosen = new Set<string>();
  const overCap: string[] = [];
  let tokens = hasDeferred
    ? schemaTokens(toToolDefinition(byName.get(SEARCH_TOOLS_NAME)!))
    : 0;
  for (const name of wanted) {
    const definition = definitionOf(name);
    if (!definition) {
      continue;
    }
    const cost = schemaTokens(definition);
    if (
      chosen.size >= seats ||
      (chosen.size > 0 && tokens + cost > caps.schemaTokens)
    ) {
      overCap.push(name);
      continue;
    }
    chosen.add(name);
    tokens += cost;
  }
  if (hasDeferred) {
    chosen.add(SEARCH_TOOLS_NAME);
  }

  // Emit in a canonical order: catalogue order, then the pal's own tools.
  // A tool the message asked for goes to the front: small models take the
  // first tool that fits loosely (LFM3 answered "where am I" with a web
  // search while get_location sat further down the list).
  const tools: ToolDefinition[] = [];
  const front = new Set(matched.slice(0, MAX_MATCHED).map(tool => tool.name));
  for (const tool of input.catalog) {
    if (chosen.has(tool.name) && front.has(tool.name)) {
      tools.push(toToolDefinition(tool));
    }
  }
  for (const tool of input.catalog) {
    if (chosen.has(tool.name) && !front.has(tool.name)) {
      tools.push(toToolDefinition(tool));
    }
  }
  for (const tool of baseKept) {
    if (chosen.has(tool.function.name)) {
      tools.push(tool);
    }
  }
  return {
    tools,
    names: tools.map(tool => tool.function.name),
    offline,
    overCap,
    superseded,
  };
}

export interface ToolSelectionOptions {
  catalog?: ToolCatalog;
  /** Defaults to the injected connectivity flag. */
  online?: () => boolean;
  /**
   * Run the forced search inside `prepareRequest` and hand the model the
   * results as a tool exchange. This is how the direct search reaches
   * upstream's agent loop, which AntiChat does not own. Default true.
   */
  directSearch?: boolean;
  /** Add the date table to turns that use relative dates. Default true. */
  dateTable?: boolean;
  /** Attachment on the newest message (the gate then leaves search to the model). */
  hasAttachment?: (context: RequestContext) => boolean;
}

const GENERIC_NAME_WORDS = new Set([
  'list',
  'create',
  'search',
  'send',
  'get',
  'set',
  'add',
  'read',
  'find',
  'update',
  'delete',
  'events',
  'event',
  'items',
  'item',
  'tools',
  'tool',
  'url',
  'web',
  'time',
  'date',
  'units',
  'convert',
  'new',
  'all',
  'my',
  'the',
]);

const PINNED_WEB = ['web_search', 'read_url'];
const MAX_MATCHED = 4;
/** Keywords too common to choose a tool by. */
const WEAK_KEYWORDS = new Set([
  'where',
  'near',
  'find',
  'app',
  'apps',
  'account',
  'run',
  'send',
  'create',
  'do',
  'connected',
  'actions',
  'search',
  'current',
  'internet',
  'news',
  'look up',
  'arguments',
  'schema',
  'parameters',
  'time',
  'date',
  'convert',
]);

const wholeWord = (text: string, word: string): boolean => {
  const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(
    `(?<![\\p{L}\\p{N}])${escaped}s?(?![\\p{L}\\p{N}])`,
    'iu',
  ).test(text);
};

/**
 * Tools the message asks for by keyword or trigger (web tools excluded),
 * best match first. Cheap on purpose: it runs on every send.
 */
export function matchingTools(
  userText: string,
  tools: readonly AntichatTool[],
): AntichatTool[] {
  const text = userText.toLowerCase();
  const scored: Array<{tool: AntichatTool; score: number}> = [];
  for (const tool of tools) {
    if (PINNED_WEB.includes(tool.name) || tool.name === SEARCH_TOOLS_NAME) {
      continue;
    }
    let score = 0;
    for (const trigger of tool.triggers ?? []) {
      if (wholeWord(text, trigger.toLowerCase())) {
        score += 3;
      }
    }
    for (const keyword of tool.keywords ?? []) {
      const word = keyword.toLowerCase();
      if (
        word.length >= 3 &&
        !WEAK_KEYWORDS.has(word) &&
        wholeWord(text, word)
      ) {
        score += 1;
      }
    }
    if (score > 0) {
      scored.push({tool, score});
    }
  }
  return scored.sort((a, b) => b.score - a.score).map(entry => entry.tool);
}

/**
 * Does the message name an offered tool other than the web tools? Name words
 * ("calendar", "email", "timer", "weather") and the tool's `triggers`, matched
 * as whole words.
 */
export function namesOtherTool(
  userText: string,
  offered: readonly AntichatTool[],
): boolean {
  const text = userText.toLowerCase();
  for (const tool of offered) {
    if (
      tool.name === 'web_search' ||
      tool.name === 'read_url' ||
      tool.name === SEARCH_TOOLS_NAME
    ) {
      continue;
    }
    const words = [
      ...tool.name
        .toLowerCase()
        .split(/[_.-]+/)
        .filter(word => word.length > 2 && !GENERIC_NAME_WORDS.has(word)),
      ...(tool.triggers ?? []).map(word => word.toLowerCase()),
    ];
    for (const word of words) {
      const escaped = word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      if (
        new RegExp(
          `(?<![\\p{L}\\p{N}])(?:e-)?${escaped}s?(?![\\p{L}\\p{N}])`,
          'iu',
        ).test(text)
      ) {
        return true;
      }
    }
  }
  return false;
}

export interface ToolsMeta {
  turnId: string;
  selected: string[];
  offline: string[];
  overCap: string[];
  verdict: SearchVerdict;
  /** The harness searched before the model ran. */
  forcedSearch: boolean;
  /** The turn wanted the web but the device is offline. */
  offlineBlocked: boolean;
  chips: ChipId[];
}

interface Plan {
  selection: Selection;
  verdict: SearchVerdict;
  caps: ToolCaps;
  turnId: string;
  online: boolean;
  chips: ChipId[];
  meta: ToolsMeta;
}

let turnCounter = 0;

const previousUserTexts = (messages: readonly ChatMessage[]): string[] => {
  const texts = messages
    .filter(message => message.role === 'user')
    .map(message => messageText(message as ChatMessage).text);
  return texts.slice(0, -1);
};

export function createToolSelectionProvider(
  options: ToolSelectionOptions = {},
): RequestProvider {
  const catalog = options.catalog ?? toolCatalog;
  const plans = new WeakMap<object, Plan>();

  const plan = (context: RequestContext): Plan => {
    const existing = plans.get(context);
    if (existing) {
      return existing;
    }
    const {runtime, session} = context;
    // An offline chat behaves as if the phone had no connection.
    const online = (options.online ?? isOnline)() && !session.offline;
    const caps = toolCapsFor(runtime.modelName, runtime.family, runtime.nCtx);
    // A chip switched on before the chat had an id sits in the shared slot.
    const chips = [
      ...new Set([...activeChips(session.id), ...activeChips(undefined)]),
    ];
    const selection = selectTools({
      catalog: catalog
        .all()
        .filter(
          tool =>
            (isLocationAllowed() || tool.name !== LOCATION_TOOL) &&
            (!session.offline || allowedOffline(tool.name, () => tool.kind)),
        ),
      baseTools: [...context.tools],
      chips,
      activated: activatedTools(session.id),
      online,
      caps,
      userText: context.userText,
    });
    let verdict = decideSearch({
      userText: context.userText,
      searchChip: chips.includes('search'),
      knowledgeCutoff: knowledgeCutoffFor(runtime.modelName),
      hasAttachment: options.hasAttachment?.(context),
      otherToolMatches:
        namesOtherTool(
          context.userText,
          selection.names
            .map(name => catalog.get(name))
            .filter((tool): tool is AntichatTool => !!tool),
        ) ||
        // A tool the message asked for by keyword is offered: it goes first,
        // not a web search.
        matchingTools(
          context.userText,
          selection.names
            .map(name => catalog.get(name))
            .filter((tool): tool is AntichatTool => !!tool),
        ).length > 0,
    });
    if (
      verdict.decision !== 'none' &&
      verdict.reason !== 'chip' &&
      verdict.reason !== 'explicit' &&
      (hasMemoryCue(context.userText) || hasForgetCue(context.userText))
    ) {
      // "Remember that I live in Lisbon" is for memory, never a web query:
      // a personal fact must not go to a search service.
      verdict = {decision: 'none', reason: 'stable_task'};
    }
    const turnId = `${session.id ?? 'chat'}:${Date.now().toString(36)}:${turnCounter++}`;
    const wantsWeb = verdict.decision === 'force';
    const made: Plan = {
      selection,
      verdict,
      caps,
      turnId,
      online,
      chips,
      meta: {
        turnId,
        selected: selection.names,
        offline: selection.offline,
        overCap: selection.overCap,
        verdict,
        forcedSearch: false,
        offlineBlocked: wantsWeb && !online,
        chips,
      },
    };
    plans.set(context, made);
    return made;
  };

  return {
    id: TOOL_SELECTION_PROVIDER_ID,
    order: 30,
    contribute(context): Contribution {
      const made = plan(context);
      const {selection, verdict} = made;
      const contribution: Contribution = {meta: {tools: made.meta}};
      if (selection.names.length > 0) {
        // The system-prompt provider adds this clause only when the pal
        // already had tools; same id, so it is never doubled.
        contribution.systemBlocks = [
          {id: 'tool-use', slot: 'stable', order: 80, text: TOOL_USE_CLAUSE},
        ];
        if (
          made.caps.citeRule &&
          (selection.names.includes('web_search') ||
            selection.names.includes('read_url'))
        ) {
          contribution.systemBlocks.push({
            id: 'cite',
            slot: 'stable',
            order: 82,
            text: CITE_SYSTEM_RULE,
          });
        }
      }
      const turnContext: string[] = [];
      if (made.meta.offlineBlocked) {
        turnContext.push(
          context.session.offline ? OFFLINE_CHAT_NOTE : OFFLINE_NOTE,
        );
      }
      if (
        options.dateTable !== false &&
        selection.names.length > 0 &&
        verdict.decision !== 'none' &&
        RELATIVE_DATE.test(context.userText)
      ) {
        turnContext.push(upcomingDatesLine(context.runtime.now));
      }
      if (turnContext.length > 0) {
        contribution.turnContext = turnContext;
      }
      if (
        verdict.decision === 'none' &&
        selection.names.length > 0 &&
        made.caps.softWithhold
      ) {
        contribution.params = {tool_choice: 'none'} as Contribution['params'];
      }
      return contribution;
    },
    async transform(
      draft: RequestDraft,
      context: RequestContext,
    ): Promise<RequestDraft> {
      const made = plan(context);
      const {selection, verdict, caps} = made;
      const offered = selection.names
        .map(name => catalog.get(name))
        .filter((tool): tool is AntichatTool => !!tool);
      const guards = {
        repair: new RepairState(),
        guard: new LoopGuard({
          ...LOOP_POLICY[context.runtime.deviceClass],
          maxSteps: caps.maxSteps,
          maxCallsPerStep: caps.parallelCalls,
        }),
      };
      const toolContext = {
        now: context.runtime.now,
        timeZone: context.runtime.timeZone,
        locale: context.session.locale,
        userText: context.userText,
        nCtx: context.runtime.nCtx,
        deviceClass: context.runtime.deviceClass,
        turnId: made.turnId,
        signal: context.runtime.signal,
      };
      beginTurn({
        turnId: made.turnId,
        chatId: context.session.id,
        guards,
        offered,
        context: toolContext,
        resultChars: caps.resultChars,
      });
      let messages = draft.messages;
      const searchTool = offered.find(tool => tool.name === 'web_search');
      if (
        verdict.decision === 'force' &&
        searchTool &&
        caps.directSearch &&
        options.directSearch !== false &&
        !context.runtime.signal?.aborted
      ) {
        const query = getSearchService().directQueries({
          userText: context.userText,
          previousUserTexts: previousUserTexts(context.messages),
          now: context.runtime.now,
          nCtx: context.runtime.nCtx,
          deviceClass: context.runtime.deviceClass,
        })[0];
        if (query) {
          const callId = `direct-${made.turnId}`;
          const result = await executeGuarded({
            callId,
            turnId: made.turnId,
            name: 'web_search',
            rawArguments: {query},
            offered,
            guards,
            context: toolContext,
            resultChars: caps.resultChars,
            synthetic: true,
          });
          if (result.status === 'ok' || result.status === 'tool_error') {
            made.meta.forcedSearch = true;
            messages = [
              ...messages,
              {
                role: 'assistant',
                content: '',
                tool_calls: [
                  {
                    id: callId,
                    type: 'function',
                    function: {
                      name: 'web_search',
                      arguments: JSON.stringify(result.args ?? {query}),
                    },
                  },
                ],
              },
              {role: 'tool', tool_call_id: callId, content: result.content},
            ];
          }
        }
      }
      consumeOneShotChips(context.session.id);
      consumeOneShotChips(undefined);
      // A model that ignores `tool_choice: none` gets no tools for a turn
      // that needs none (the turn's cache is the price).
      const withheld = verdict.decision === 'none' && !caps.softWithhold;
      // Tools other providers added (memory, connectors): the selection only
      // knows the catalogue and the pal's own list, so they are carried over
      // here. They keep their seats; catalogue tools give way under the cap,
      // never the two pinned web tools.
      const known = new Set([
        ...context.tools.map(tool => tool.function.name),
        ...selection.names,
        ...selection.overCap,
      ]);
      const extras = draft.tools.filter(
        tool =>
          !known.has(tool.function.name) && !catalog.get(tool.function.name),
      );
      const kept = selection.tools.slice(
        0,
        Math.max(2, caps.maxTools - extras.length),
      );
      return {
        ...draft,
        messages,
        // A turn that needs no catalogue tool still gets the providers' own.
        tools: withheld ? extras : [...kept, ...extras],
        meta: {...draft.meta, tools: made.meta},
      };
    },
  };
}
