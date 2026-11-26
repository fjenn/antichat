import React, {useEffect, useRef, useState} from 'react';
import {Modal, Pressable, TextInput, View} from 'react-native';
import {observer} from 'mobx-react';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {useT} from '../../locales';
import {typography} from '../../theme';
import {renameChat} from '../drawer/historyActions';
import {historyUi} from '../drawer/historyUi';
import {Button, Text} from '../primitives';

/**
 * Rename from the chat's own ••• menu, where there is no row to edit in
 * place: a small card over the chat with the title in a field. Mounted once
 * (`HistoryOverlays`); opened with `historyUi.openRenameDialog`.
 */
export const RenameDialog = observer(function RenameChatDialog() {
  const t = useT();
  const {theme} = useUnistyles();
  const target = historyUi.renameDialogFor;
  const [value, setValue] = useState('');
  const input = useRef<React.ComponentRef<typeof TextInput>>(null);

  useEffect(() => {
    if (target) {
      setValue(target.title);
    }
  }, [target]);

  const close = () => historyUi.openRenameDialog(null);
  const save = () => {
    if (target) {
      renameChat(target, value);
    }
    close();
  };

  return (
    <Modal
      visible={target !== null}
      transparent
      animationType="fade"
      statusBarTranslucent
      navigationBarTranslucent
      onShow={() => input.current?.focus()}
      onRequestClose={close}>
      <View style={styles.layer}>
        <Pressable
          accessibilityLabel={t('common.cancel')}
          accessibilityRole="button"
          onPress={close}
          style={StyleSheet.absoluteFill}
        />
        <View
          testID="rename-dialog"
          accessibilityViewIsModal
          style={styles.card}>
          <Text variant="headline" align="center" accessibilityRole="header">
            {t('rename.title')}
          </Text>
          <TextInput
            ref={input}
            testID="rename-dialog-field"
            value={value}
            onChangeText={setValue}
            accessibilityLabel={t('chatRow.renameField')}
            selectTextOnFocus
            returnKeyType="done"
            maxLength={120}
            maxFontSizeMultiplier={typography.button.maxFontSizeMultiplier}
            selectionColor={theme.colors.accent}
            cursorColor={theme.colors.accent}
            keyboardAppearance={theme.dark ? 'dark' : 'light'}
            onSubmitEditing={save}
            style={styles.input}
          />
          <View style={styles.buttons}>
            <Button
              testID="rename-dialog-cancel"
              label={t('common.cancel')}
              variant="secondary"
              onPress={close}
              style={styles.button}
            />
            <Button
              testID="rename-dialog-save"
              label={t('rename.save')}
              disabled={value.trim().length === 0}
              onPress={save}
              style={styles.button}
            />
          </View>
        </View>
      </View>
    </Modal>
  );
});

const styles = StyleSheet.create((theme, rt) => ({
  layer: {
    flex: 1,
    alignItems: 'center',
    // Above the keyboard on every phone: the card sits in the upper half.
    paddingTop: rt.insets.top + rt.screen.height * 0.18,
    paddingHorizontal: theme.spacing.xxl,
    backgroundColor: theme.colors.scrim,
  },
  card: {
    width: '100%',
    maxWidth: 360,
    gap: theme.spacing.lg,
    padding: theme.spacing.xl,
    borderRadius: theme.radii.xl,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.backgroundElevated,
    boxShadow: theme.elevation.floating,
  },
  input: {
    minHeight: 48,
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: theme.spacing.sm,
    borderRadius: theme.radii.md,
    borderCurve: 'continuous',
    backgroundColor: theme.colors.surface,
    fontSize: typography.body.fontSize,
    letterSpacing: typography.body.letterSpacing,
    color: theme.colors.textPrimary,
    textAlign: 'auto',
  },
  buttons: {
    flexDirection: 'row',
    gap: theme.spacing.md,
  },
  button: {
    flex: 1,
  },
}));
