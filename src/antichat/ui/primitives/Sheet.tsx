import React, {forwardRef, useImperativeHandle, useRef} from 'react';
import {View} from 'react-native';
import {TrueSheet, type SheetDetent} from '@lodev09/react-native-true-sheet';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {HAS_LIQUID_GLASS} from './GlassSurface';
import {Text} from './Text';

export interface SheetHandle {
  present: () => Promise<void>;
  dismiss: () => Promise<void>;
}

export interface SheetProps {
  children: React.ReactNode;
  title?: string;
  /** Heights the sheet rests at. Default: as tall as its content. */
  detents?: SheetDetent[];
  onDismiss?: () => void;
  testID?: string;
}

/**
 * A native bottom sheet (UISheetPresentationController / Material bottom
 * sheet). On iOS 26 the system gives it glass; elsewhere it takes the
 * elevated background of the theme.
 */
export const Sheet = forwardRef<SheetHandle, SheetProps>(function NativeSheet(
  {children, title, detents = ['auto'], onDismiss, testID},
  ref,
) {
  const {theme} = useUnistyles();
  const sheet = useRef<TrueSheet>(null);

  useImperativeHandle(ref, () => ({
    present: async () => sheet.current?.present(),
    dismiss: async () => sheet.current?.dismiss(),
  }));

  const glassTint = HAS_LIQUID_GLASS
    ? {
        backgroundColor: theme.dark
          ? 'rgba(33, 33, 33, 0.88)'
          : 'rgba(255, 255, 255, 0.92)',
      }
    : undefined;

  return (
    <TrueSheet
      ref={sheet}
      detents={detents}
      grabber
      cornerRadius={theme.radii.sheet}
      backgroundColor={
        HAS_LIQUID_GLASS ? undefined : theme.colors.backgroundElevated
      }
      // The glass alone took on the dim behind it: in light mode the sheet
      // turned grey and its rows were hard to read. Tinted near-opaque in
      // the scheme's elevated colour, like ChatGPT's sheets.
      backgroundStyle={glassTint}
      dimmed
      // A light veil, not a blackout: the chat stays visible behind it.
      dimColor="#000000"
      dimOpacity={theme.dark ? 0.4 : 0.14}
      onDidDismiss={onDismiss}>
      <View testID={testID} style={styles.content}>
        {title ? (
          <Text variant="headline" align="center" accessibilityRole="header">
            {title}
          </Text>
        ) : null}
        {children}
      </View>
    </TrueSheet>
  );
});

const styles = StyleSheet.create(theme => ({
  content: {
    paddingTop: theme.spacing.xxl,
    paddingHorizontal: theme.spacing.xl,
    // M6: TrueSheet already keeps the content above the home indicator;
    // adding the inset again left a blank band under the last button.
    paddingBottom: theme.spacing.lg,
    gap: theme.spacing.lg,
  },
}));
