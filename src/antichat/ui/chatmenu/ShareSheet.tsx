import React, {useEffect, useRef, useState} from 'react';
import {View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet} from 'react-native-unistyles';

import type {ExportFormat} from '../../adapters/history';
import type {ConversationView} from '../../contracts';
import {useT, type MessageKey} from '../../locales';
import {historyUi} from '../drawer/historyUi';
import {
  ListRow,
  Sheet,
  toast,
  type IconName,
  type SheetHandle,
} from '../primitives';
import {EXPORT_FORMATS, exportChat, shareExport} from './exportChat';

const ROWS: Record<
  ExportFormat,
  {icon: IconName; title: MessageKey; subtitle: MessageKey}
> = {
  markdown: {
    icon: 'document',
    title: 'share.markdown',
    subtitle: 'share.markdownHint',
  },
  text: {icon: 'plainText', title: 'share.text', subtitle: 'share.textHint'},
  chatgpt: {
    icon: 'json',
    title: 'share.chatgpt',
    subtitle: 'share.chatgptHint',
  },
};

/**
 * "Share chat": pick a format, then the system share sheet takes over.
 * Mounted once (`HistoryOverlays`); opened with `historyUi.openShare`.
 */
export const ShareSheet = observer(function ShareChatSheet() {
  const t = useT();
  const sheet = useRef<SheetHandle>(null);
  const target = historyUi.shareFor;
  const [busy, setBusy] = useState<ExportFormat | null>(null);
  // The chat stays known while the sheet animates away.
  const shown = useRef<ConversationView | null>(null);
  if (target) {
    shown.current = target;
  }

  useEffect(() => {
    if (target) {
      sheet.current?.present().catch(() => {});
    }
  }, [target]);

  const pick = async (format: ExportFormat) => {
    const conversation = shown.current;
    if (!conversation || busy) {
      return;
    }
    setBusy(format);
    try {
      const exported = await exportChat(conversation, format);
      await sheet.current?.dismiss();
      await shareExport(exported);
    } catch {
      toast.show({message: t('share.failed'), kind: 'error'});
    } finally {
      setBusy(null);
    }
  };

  return (
    <Sheet
      ref={sheet}
      testID="share-sheet"
      title={t('share.title')}
      onDismiss={() => historyUi.openShare(null)}>
      <View style={styles.rows}>
        {EXPORT_FORMATS.map(format => (
          <ListRow
            key={format}
            testID={`share-${format}`}
            icon={ROWS[format].icon}
            title={t(ROWS[format].title)}
            subtitle={t(ROWS[format].subtitle)}
            disabled={busy !== null && busy !== format}
            onPress={() => {
              pick(format).catch(() => {});
            }}
          />
        ))}
      </View>
    </Sheet>
  );
});

const styles = StyleSheet.create(theme => ({
  rows: {
    marginHorizontal: -theme.spacing.sm,
  },
}));
