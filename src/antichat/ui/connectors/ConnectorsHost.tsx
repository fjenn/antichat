import React, {useEffect, useRef} from 'react';
import {AppState, Linking} from 'react-native';
import {observer} from 'mobx-react';

import {handleConnectorLink} from '../../engine/mcp/platform';
import type {ConnectorsStore} from '../../engine/mcp/store';
import {Sheet, type SheetHandle} from '../primitives';
import {ApprovalCard} from './ApprovalCard';
import {ConnectAppCard} from './ConnectAppCard';
import {useConnectors} from './session';

export interface ConnectorsHostProps {
  onOpenConnectors?: () => void;
  /**
   * The chat draws `connect_app` cards itself (inline, with
   * `ConnectAppCard`). Until it does, the host shows the card in a sheet.
   */
  inlineCards?: boolean;
}

/**
 * Mounted once near the root. Switches connectors on, routes the deep links
 * that come back from a sign-in, and shows the two things a connector can
 * ask at any moment: approval of a write action, and the Connect card.
 */
export function ConnectorsHost(props: ConnectorsHostProps) {
  const store = useConnectors();

  useEffect(() => {
    const onLink = (url?: string | null) => {
      if (handleConnectorLink(url) === 'connected') {
        store.connectionMayHaveChanged();
      }
    };
    Linking.getInitialURL()
      .then(onLink)
      .catch(() => {});
    const links = Linking.addEventListener('url', event => onLink(event.url));
    // Coming back from the browser without a deep link: check on foreground.
    const state = AppState.addEventListener('change', next => {
      if (next === 'active' && store.connecting) {
        store.connectionMayHaveChanged();
      }
    });
    return () => {
      links.remove();
      state.remove();
    };
  }, [store]);

  return <ConnectorsSheets store={store} {...props} />;
}

export const ConnectorsSheets = observer(function Sheets({
  store,
  onOpenConnectors,
  inlineCards = false,
}: ConnectorsHostProps & {store: ConnectorsStore}) {
  const approvalSheet = useRef<SheetHandle>(null);
  const cardSheet = useRef<SheetHandle>(null);
  const request = store.approvals[0];
  const card = inlineCards ? null : store.card;
  const requestId = request?.id;
  const cardId = card?.id;

  useEffect(() => {
    if (requestId) {
      approvalSheet.current?.present().catch(() => {});
    } else {
      approvalSheet.current?.dismiss().catch(() => {});
    }
  }, [requestId]);

  useEffect(() => {
    if (cardId) {
      cardSheet.current?.present().catch(() => {});
    } else {
      cardSheet.current?.dismiss().catch(() => {});
    }
  }, [cardId]);

  return (
    <>
      <Sheet
        ref={approvalSheet}
        testID="approval-sheet"
        // Swiped away without an answer: not allowed.
        onDismiss={() => requestId && store.answerApproval(requestId, 'deny')}>
        {request ? (
          <ApprovalCard
            request={request}
            logo={
              store.online
                ? store.toolkits.find(toolkit => toolkit.name === request.app)
                    ?.logo
                : undefined
            }
            onAnswer={answer => store.answerApproval(request.id, answer)}
          />
        ) : null}
      </Sheet>
      <Sheet
        ref={cardSheet}
        testID="connect-card-sheet"
        onDismiss={() => store.dismissCard()}>
        {card ? (
          <ConnectAppCard
            store={store}
            slug={card.slug}
            name={card.name}
            plain
            onConnected={() => store.dismissCard()}
            onOpenConnectors={() => {
              store.dismissCard();
              onOpenConnectors?.();
            }}
          />
        ) : null}
      </Sheet>
    </>
  );
});
