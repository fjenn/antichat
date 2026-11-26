/**
 * The one place that decides, per port, whether the app talks to the real
 * engine or to an in-memory fake. Integrating a milestone is a one-line swap
 * in `REAL` below; nothing else in the UI changes.
 */
import type {PortName, Ports} from '../contracts';
import {createFakePorts} from '../contracts/fakes';
import {currentBackend, fakeOptions} from './backend';

/**
 * Real implementations, as each milestone lands (required lazily, so a build
 * running on the fakes never loads the engine behind them):
 *
 *   model:         () => require('./model').modelPort,                // M5
 *   connectivity:  () => require('./model').connectivity,             // M5
 *   tools:         () => require('./tools').toolsPort,                // M8
 *   memory:        () => require('./memory').memoryPort,              // M9
 *   files:         () => require('./files').filesPort,                // M10
 *   voice:         () => require('./voice').voicePort,                // M11
 *
 * A port missing here is served by its fake. With the fake backend selected
 * (`./backend`, debug builds) every port is a fake.
 */
const REAL: {[Name in PortName]?: () => Ports[Name]} = {
  chat: () => require('./chat').chatPort(), // M2
  // M4's history port: M3's store as the synchronous list the drawer reads.
  conversations: () => require('./history').historyPort(), // M3 + M4
  // M5's model engine: the one runtime `installEngine()` created (M6's
  // screens read it through `ui/models/shared`).
  model: () => require('./model').sharedModelRuntime().engine,
  connectivity: () => require('./connectivity').connectivity,
  // M11, dictation only: the engine is built on the first microphone tap.
  voice: () => require('./voice').voicePort(),
  // The + sheet's web search switch; the engine picks every other tool.
  tools: () =>
    require('./tools').toolsPort(require('./connectivity').connectivity),
};

function realFactories(): typeof REAL {
  return currentBackend() === 'real' ? REAL : {};
}

let ports: Ports | undefined;

function build(): Ports {
  const real = realFactories();
  const fakes = createFakePorts({chat: fakeOptions()});
  const result: Ports = {...fakes};
  (Object.keys(real) as PortName[]).forEach(name => {
    const factory = real[name] as (() => Ports[PortName]) | undefined;
    if (factory) {
      (result as unknown as Record<PortName, Ports[PortName]>)[name] =
        factory();
    }
  });
  return result;
}

/** The app's ports. Built on first use. */
export function getPorts(): Ports {
  ports ??= build();
  return ports;
}

/** Which ports are still fakes; shown in the design gallery and in logs. */
export function fakePortNames(): PortName[] {
  const all: PortName[] = [
    'chat',
    'conversations',
    'model',
    'tools',
    'memory',
    'files',
    'voice',
    'connectivity',
  ];
  const real = realFactories();
  return all.filter(name => !real[name]);
}

/** Tests and screenshots: replace the ports (or reset with no argument). */
export function setPorts(next?: Ports): void {
  ports = next;
}

export {usePort} from './usePort';
