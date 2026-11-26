import React, {forwardRef, useState} from 'react';
import {
  TextInput,
  View,
  type StyleProp,
  type TextInputProps,
  type ViewStyle,
} from 'react-native';
import {StyleSheet, useUnistyles} from 'react-native-unistyles';

import {translate} from '../../locales';
import {typography} from '../../theme';
import {Icon} from './Icon';
import type {IconName} from './icons';
import {PressableScale} from './PressableScale';
import {Text} from './Text';

export interface TextFieldProps
  extends Omit<TextInputProps, 'style' | 'placeholderTextColor'> {
  /** Shown above the field and read as its accessibility label. */
  label?: string;
  error?: string;
  icon?: IconName;
  /** `pill` is the search field shape. */
  shape?: 'field' | 'pill';
  /** Show a clear button while there is text. */
  clearable?: boolean;
  containerStyle?: StyleProp<ViewStyle>;
}

export type TextFieldRef = React.ComponentRef<typeof TextInput>;

export const TextField = forwardRef<TextFieldRef, TextFieldProps>(
  function Field(
    {
      label,
      error,
      icon,
      shape = 'field',
      clearable = false,
      containerStyle,
      value,
      onChangeText,
      onFocus,
      onBlur,
      accessibilityLabel,
      ...rest
    },
    ref,
  ) {
    const {theme} = useUnistyles();
    const [focused, setFocused] = useState(false);
    return (
      <View style={[styles.container, containerStyle]}>
        {label ? (
          <Text variant="footnote" color="textSecondary" style={styles.label}>
            {label}
          </Text>
        ) : null}
        <View style={styles.field(shape, focused, Boolean(error))}>
          {icon ? <Icon name={icon} size={18} color="textTertiary" /> : null}
          <TextInput
            ref={ref}
            {...rest}
            value={value}
            onChangeText={onChangeText}
            accessibilityLabel={accessibilityLabel ?? label ?? rest.placeholder}
            placeholderTextColor={theme.colors.textTertiary}
            selectionColor={theme.colors.accent}
            cursorColor={theme.colors.accent}
            keyboardAppearance={theme.dark ? 'dark' : 'light'}
            // A single-line field cannot grow sideways; cap it like a control.
            maxFontSizeMultiplier={typography.button.maxFontSizeMultiplier}
            onFocus={event => {
              setFocused(true);
              onFocus?.(event);
            }}
            onBlur={event => {
              setFocused(false);
              onBlur?.(event);
            }}
            style={styles.input}
          />
          {clearable && value ? (
            <PressableScale
              accessibilityRole="button"
              accessibilityLabel={translate('common.clear')}
              hitSlop={12}
              onPress={() => onChangeText?.('')}
              style={styles.clear}>
              <Icon name="close" size={12} color="background" strokeWidth={3} />
            </PressableScale>
          ) : null}
        </View>
        {error ? (
          <Text
            variant="footnote"
            color="danger"
            accessibilityLiveRegion="polite"
            style={styles.label}>
            {error}
          </Text>
        ) : null}
      </View>
    );
  },
);

const styles = StyleSheet.create(theme => ({
  container: {
    gap: theme.spacing.xs + theme.spacing.xxs,
  },
  label: {
    paddingHorizontal: theme.spacing.xs,
  },
  field: (shape: 'field' | 'pill', focused: boolean, invalid: boolean) => ({
    minHeight: shape === 'pill' ? 40 : 48,
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.sm,
    paddingHorizontal: shape === 'pill' ? theme.spacing.md : theme.spacing.lg,
    borderRadius: shape === 'pill' ? theme.radii.pill : theme.radii.md,
    backgroundColor: theme.colors.surface,
    borderWidth: 1,
    borderColor: invalid
      ? theme.colors.danger
      : focused && shape === 'field'
        ? theme.colors.textTertiary
        : 'transparent',
  }),
  input: {
    flex: 1,
    paddingVertical: theme.spacing.sm,
    fontSize: typography.body.fontSize,
    letterSpacing: typography.body.letterSpacing,
    color: theme.colors.textPrimary,
    textAlign: 'auto',
  },
  clear: {
    width: 18,
    height: 18,
    borderRadius: 9,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: theme.colors.textTertiary,
  },
}));
