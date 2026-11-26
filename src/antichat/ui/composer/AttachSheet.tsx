import React, {forwardRef, useImperativeHandle, useRef} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {getPorts, usePort} from '../../adapters';
import type {PickSource} from '../../contracts';
import {useT} from '../../locales';
import {
  Icon,
  ListRow,
  PressableScale,
  Sheet,
  Text,
  type IconName,
  type SheetHandle,
} from '../primitives';
import {openConnectorsScreen} from '../../app/navigate';
import {V1} from '../../app/scope';
import type {ToolView} from '../../contracts';
import {s as connectorStrings} from '../connectors/strings';
import {TOOL_ICONS, toolName} from './toolKinds';

/** Tool kinds the first version leaves out of the sheet. */
const OUT_OF_SCOPE: Partial<Record<ToolView['kind'], boolean>> = {
  image: !V1.images,
  research: !V1.research,
  study: !V1.study,
  think: !V1.thinkTool,
};

const SOURCES: Array<{
  source: PickSource;
  icon: IconName;
  label: 'composer.camera' | 'composer.photos' | 'composer.files';
}> = [
  {source: 'camera', icon: 'camera', label: 'composer.camera'},
  {source: 'photos', icon: 'image', label: 'composer.photos'},
  {source: 'files', icon: 'attach', label: 'composer.files'},
];

export interface AttachSheetProps {
  conversationId: string | null;
  /** Offline chat: tools and apps that need the network are greyed. */
  offline?: boolean;
}

/**
 * What the + button opens: where an attachment can come from (when in
 * scope), the tools that can be switched on for the next message, and the
 * way to the apps (connectors).
 */
export const AttachSheet = forwardRef<SheetHandle, AttachSheetProps>(
  function Attach({conversationId, offline = false}, ref) {
    const t = useT();
    const sheet = useRef<SheetHandle>(null);
    const {files, tools} = getPorts();
    const list = usePort(tools, port =>
      port.tools.filter(tool => tool.selectable && !OUT_OF_SCOPE[tool.kind]),
    );
    const active = usePort(tools, port => port.activeToolIds(conversationId));

    useImperativeHandle(ref, () => ({
      present: async () => sheet.current?.present(),
      dismiss: async () => sheet.current?.dismiss(),
    }));

    const pick = (source: PickSource) => {
      sheet.current?.dismiss().catch(() => {});
      files.pick(conversationId, source).catch(() => {});
    };

    return (
      <Sheet ref={sheet} testID="attach-sheet">
        {V1.attachments ? (
          <View style={styles.sources}>
            {SOURCES.map(({source, icon, label}) => (
              <PressableScale
                key={source}
                testID={`attach-${source}`}
                accessibilityRole="button"
                accessibilityLabel={t(label)}
                haptic
                onPress={() => pick(source)}
                style={styles.source}>
                <Icon name={icon} size={24} />
                <Text variant="footnote" numberOfLines={1}>
                  {t(label)}
                </Text>
              </PressableScale>
            ))}
          </View>
        ) : null}
        {list.length > 0 ? (
          <View accessibilityLabel={t('composer.tools')} style={styles.tools}>
            {list.map(tool => {
              const blocked = offline && tool.online;
              const on = active.includes(tool.id) && !blocked;
              return (
                <ListRow
                  key={tool.id}
                  testID={`tool-${tool.id}`}
                  icon={TOOL_ICONS[tool.kind]}
                  title={tool.displayName ?? t(toolName(tool.kind))}
                  subtitle={
                    blocked
                      ? t('composer.toolOfflineChat')
                      : tool.unavailableReason === 'offline'
                        ? t('composer.toolOffline')
                        : undefined
                  }
                  titleLines={1}
                  disabled={blocked || !tool.available}
                  selected={on}
                  trailing={
                    on ? <Icon name="check" size={20} color="accent" /> : null
                  }
                  onPress={() => {
                    tools.setActive(conversationId, tool.id, !on);
                    sheet.current?.dismiss().catch(() => {});
                  }}
                />
              );
            })}
          </View>
        ) : null}
        <View style={styles.tools}>
          <ListRow
            testID="attach-apps"
            icon="apps"
            title={connectorStrings.apps}
            subtitle={
              offline
                ? t('composer.toolOfflineChat')
                : connectorStrings.settingsSubtitle
            }
            titleLines={1}
            disabled={offline}
            chevron={!offline}
            onPress={() => {
              sheet.current?.dismiss().catch(() => {});
              openConnectorsScreen();
            }}
          />
        </View>
      </Sheet>
    );
  },
);

const styles = StyleSheet.create(theme => ({
  sources: {
    flexDirection: 'row',
    gap: theme.spacing.sm,
  },
  source: {
    flex: 1,
    minHeight: 84,
    alignItems: 'center',
    justifyContent: 'center',
    gap: theme.spacing.sm,
    paddingVertical: theme.spacing.md,
    borderRadius: theme.radii.lg,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
  },
  tools: {
    marginHorizontal: -theme.spacing.sm,
  },
}));
