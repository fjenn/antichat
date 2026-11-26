import React, {useState} from 'react';
import {TextInput, View} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {typography} from '../../../theme';
import {Text} from '../../primitives';

export interface TextAreaProps {
  value: string;
  onChangeText: (text: string) => void;
  /** Called when editing ends, with the final text. */
  onCommit?: (text: string) => void;
  placeholder: string;
  accessibilityLabel: string;
  maxLength: number;
  /** One line (a name) instead of a paragraph. */
  singleLine?: boolean;
  testID?: string;
}

/**
 * A text field drawn as part of a settings card. Shows how much room is left
 * once the text gets close to the limit.
 */
export function TextArea({
  value,
  onChangeText,
  onCommit,
  placeholder,
  accessibilityLabel,
  maxLength,
  singleLine = false,
  testID,
}: TextAreaProps) {
  const {theme} = useUnistyles();
  const [focused, setFocused] = useState(false);
  const nearLimit = value.length >= maxLength * 0.8;
  return (
    <View style={styles.box(singleLine)}>
      <TextInput
        testID={testID}
        value={value}
        onChangeText={onChangeText}
        onFocus={() => setFocused(true)}
        onBlur={() => {
          setFocused(false);
          onCommit?.(value);
        }}
        placeholder={placeholder}
        placeholderTextColor={theme.colors.textTertiary}
        accessibilityLabel={accessibilityLabel}
        selectionColor={theme.colors.accent}
        cursorColor={theme.colors.accent}
        keyboardAppearance={theme.dark ? 'dark' : 'light'}
        maxLength={maxLength}
        multiline={!singleLine}
        scrollEnabled={false}
        textAlignVertical="top"
        maxFontSizeMultiplier={typography.body.maxFontSizeMultiplier}
        style={styles.input(singleLine)}
      />
      {!singleLine && (focused || nearLimit) ? (
        <Text
          variant="caption"
          color={value.length >= maxLength ? 'danger' : 'textTertiary'}
          align="right">
          {value.length} / {maxLength}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  box: (singleLine: boolean) => ({
    paddingHorizontal: theme.spacing.lg,
    paddingVertical: singleLine ? theme.spacing.xs : theme.spacing.md,
    gap: theme.spacing.xs,
  }),
  input: (singleLine: boolean) => ({
    minHeight: singleLine ? 44 : 96,
    padding: 0,
    fontSize: typography.body.fontSize,
    lineHeight: singleLine ? undefined : typography.body.lineHeight,
    letterSpacing: typography.body.letterSpacing,
    color: theme.colors.textPrimary,
    textAlign: 'auto',
  }),
}));
