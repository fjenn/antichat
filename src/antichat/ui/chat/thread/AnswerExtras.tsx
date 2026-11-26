import React, {useSyncExternalStore} from 'react';
import {Linking, ScrollView, View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {
  clearConnectCard,
  subscribeTurnExtras,
  turnExtrasFor,
} from '../../../adapters/turnExtras';
import {openConnectorsScreen} from '../../../app/navigate';
import {ConnectAppCard, useConnectors} from '../../connectors';
import {Icon, PressableScale, Text} from '../../primitives';

/**
 * Under an answer: the web pages it drew on, as pills that open the page,
 * and the Connect card when the model needed an app that is not connected.
 */
export function AnswerExtras({messageId}: {messageId: string}) {
  const extras = useSyncExternalStore(subscribeTurnExtras, () =>
    turnExtrasFor(messageId),
  );
  if (extras.citations.length === 0 && !extras.connect) {
    return null;
  }
  return (
    <View style={styles.wrap}>
      {extras.connect ? (
        <ConnectCard messageId={messageId} card={extras.connect} />
      ) : null}
      {extras.citations.length > 0 ? (
        <ScrollView
          testID="answer-sources"
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={styles.sources}>
          <View style={styles.label}>
            <Icon name="web" size={14} color="textSecondary" />
            <Text variant="footnote" color="textSecondary">
              Sources
            </Text>
          </View>
          {extras.citations.slice(0, 8).map((citation, index) => (
            <PressableScale
              key={citation.id}
              testID={`answer-source-${index + 1}`}
              accessibilityRole="link"
              accessibilityLabel={`${citation.source}: ${citation.title}`}
              style={styles.pill}
              onPress={() => {
                Linking.openURL(citation.url).catch(() => {});
              }}>
              <Text variant="footnote" numberOfLines={1}>
                {index + 1} · {citation.source}
              </Text>
            </PressableScale>
          ))}
        </ScrollView>
      ) : null}
    </View>
  );
}

function ConnectCard({
  messageId,
  card,
}: {
  messageId: string;
  card: {slug: string | null; name: string};
}) {
  const store = useConnectors();
  return (
    <ConnectAppCard
      testID="connect-card"
      store={store}
      slug={card.slug}
      name={card.name}
      onConnected={() => {
        store.dismissCard();
        clearConnectCard(messageId);
      }}
      onOpenConnectors={() => {
        store.dismissCard();
        openConnectorsScreen();
      }}
    />
  );
}

const styles = StyleSheet.create(theme => ({
  wrap: {
    gap: theme.spacing.sm,
    marginTop: theme.spacing.xs,
  },
  sources: {
    alignItems: 'center',
    gap: theme.spacing.xs,
    paddingRight: theme.spacing.lg,
  },
  label: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    marginRight: theme.spacing.xs,
  },
  pill: {
    maxWidth: 180,
    paddingHorizontal: theme.spacing.sm,
    paddingVertical: 6,
    borderRadius: 14,
    backgroundColor: theme.colors.surface,
  },
}));
