import {getPorts, usePort} from '../../adapters';

/** The one `online` flag, kept current. */
export function useOnline(): boolean {
  return usePort(getPorts().connectivity, port => port.online);
}

/** On mobile data (or another connection billed by volume). */
export function useMetered(): boolean {
  return usePort(getPorts().connectivity, port => port.metered);
}
