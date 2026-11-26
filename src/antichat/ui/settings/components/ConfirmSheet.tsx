import React, {forwardRef} from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {Button, Sheet, Text, type SheetHandle} from '../../primitives';

export interface ConfirmSheetProps {
  title: string;
  message: string;
  confirmLabel: string;
  cancelLabel: string;
  destructive?: boolean;
  /** The confirm button waits for something (a consent switch). */
  confirmDisabled?: boolean;
  onConfirm: () => void;
  /** Extra content between the message and the buttons. */
  children?: React.ReactNode;
  testID?: string;
}

/**
 * The app's confirmation: a native sheet with the consequence in one
 * sentence and two buttons. Used instead of an alert.
 */
export const ConfirmSheet = forwardRef<SheetHandle, ConfirmSheetProps>(
  function Confirm(
    {
      title,
      message,
      confirmLabel,
      cancelLabel,
      destructive = false,
      confirmDisabled = false,
      onConfirm,
      children,
      testID,
    },
    ref,
  ) {
    const dismiss = () => {
      if (ref && typeof ref !== 'function') {
        ref.current?.dismiss().catch(() => {});
      }
    };
    return (
      <Sheet ref={ref} testID={testID}>
        <View style={styles.texts}>
          <Text variant="title" align="center" accessibilityRole="header">
            {title}
          </Text>
          <Text color="textSecondary" align="center">
            {message}
          </Text>
        </View>
        {children}
        <View style={styles.buttons}>
          <Button
            testID={testID ? `${testID}-confirm` : undefined}
            label={confirmLabel}
            variant={destructive ? 'destructive' : 'primary'}
            size="lg"
            fullWidth
            disabled={confirmDisabled}
            onPress={() => {
              dismiss();
              onConfirm();
            }}
          />
          <Button
            testID={testID ? `${testID}-cancel` : undefined}
            label={cancelLabel}
            variant="ghost"
            size="lg"
            fullWidth
            onPress={dismiss}
          />
        </View>
      </Sheet>
    );
  },
);

const styles = StyleSheet.create(theme => ({
  texts: {
    gap: theme.spacing.sm,
    paddingHorizontal: theme.spacing.sm,
  },
  buttons: {
    gap: theme.spacing.xs,
  },
}));
