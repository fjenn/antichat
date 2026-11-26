import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import {PressableScale, Text, haptics} from '../../primitives';

export interface SegmentedProps<T extends string> {
  options: ReadonlyArray<{id: T; label: string}>;
  value: T;
  onChange: (value: T) => void;
  /** What the control sets, for screen readers ("Warmth"). */
  accessibilityLabel: string;
  testID?: string;
}

/** A small pick-one control: Less / Default / More. */
export function Segmented<T extends string>({
  options,
  value,
  onChange,
  accessibilityLabel,
  testID,
}: SegmentedProps<T>) {
  return (
    <View
      testID={testID}
      accessibilityRole="radiogroup"
      accessibilityLabel={accessibilityLabel}
      style={styles.track}>
      {options.map(option => {
        const selected = option.id === value;
        return (
          <PressableScale
            key={option.id}
            testID={testID ? `${testID}-${option.id}` : undefined}
            accessibilityRole="radio"
            accessibilityLabel={`${accessibilityLabel}: ${option.label}`}
            accessibilityState={{selected}}
            scale={false}
            onPress={() => {
              if (!selected) {
                haptics.selection();
                onChange(option.id);
              }
            }}
            style={styles.segment(selected)}>
            <Text
              variant={selected ? 'calloutStrong' : 'callout'}
              color={selected ? 'textPrimary' : 'textSecondary'}
              numberOfLines={1}
              maxFontSizeMultiplier={1.3}>
              {option.label}
            </Text>
          </PressableScale>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  track: {
    flexDirection: 'row',
    padding: 3,
    borderRadius: theme.radii.sm + 2,
    backgroundColor: theme.colors.surfacePressed,
  },
  segment: (selected: boolean) => ({
    minHeight: 32,
    minWidth: 62,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: theme.spacing.md,
    borderRadius: theme.radii.sm - 1,
    backgroundColor: selected ? theme.colors.backgroundElevated : 'transparent',
    boxShadow: selected ? theme.elevation.raised : 'none',
  }),
}));
