import React from 'react';
import {ScrollView, View} from 'react-native';
import {KeyboardAwareScrollView} from 'react-native-keyboard-controller';
import {StyleSheet} from 'react-native-unistyles';

import {ScreenHeader} from '../../../app/screens/ScreenHeader';

export interface SettingsPageProps {
  title: string;
  children: React.ReactNode;
  /** The page has text fields: keep the focused one above the keyboard. */
  keyboard?: boolean;
  testID?: string;
}

/** A pushed settings screen: back button, centred title, grouped content. */
export function SettingsPage({
  title,
  children,
  keyboard = false,
  testID,
}: SettingsPageProps) {
  const Scroller = keyboard ? KeyboardAwareScrollView : ScrollView;
  return (
    <View testID={testID} style={styles.screen}>
      <ScreenHeader title={title} />
      <Scroller
        testID={testID ? `${testID}-scroll` : undefined}
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
        keyboardDismissMode="interactive"
        showsVerticalScrollIndicator={false}
        {...(keyboard ? {bottomOffset: 24} : null)}>
        {children}
      </Scroller>
    </View>
  );
}

const styles = StyleSheet.create((theme, rt) => ({
  screen: {
    flex: 1,
    backgroundColor: theme.colors.background,
  },
  content: {
    paddingHorizontal: theme.spacing.lg,
    paddingTop: theme.spacing.sm,
    paddingBottom: rt.insets.bottom + theme.spacing.huge,
    gap: theme.spacing.xxl,
  },
}));
