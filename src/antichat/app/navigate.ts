/**
 * Navigation from places that have no navigator of their own (a chip under
 * an answer, a notice over the composer). The app root registers the ref.
 */
type Navigate = (route: string) => void;

let navigate: Navigate | null = null;

export function setAppNavigate(next: Navigate | null): void {
  navigate = next;
}

/** The manage-memories screen (M9). */
export function openMemoryScreen(): void {
  navigate?.('Memory');
}

/** Settings > Connectors (M12). */
export function openConnectorsScreen(): void {
  navigate?.('Connectors');
}
