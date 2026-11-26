import React from 'react';
import {View} from 'react-native';
import {StyleSheet} from 'react-native-unistyles';

import type {
  ApprovalAnswer,
  ApprovalRequest,
} from '../../engine/mcp/permissions';
import {Button, Text} from '../primitives';
import {AppLogo} from './AppLogo';
import {s} from './strings';

const MAX_ROWS = 6;
const MAX_VALUE = 240;

/** The arguments as short "name: value" rows a person can check. */
export function argumentRows(
  args: Record<string, unknown>,
): Array<{name: string; value: string}> {
  return Object.entries(args)
    .filter(
      ([, value]) => value !== undefined && value !== null && value !== '',
    )
    .slice(0, MAX_ROWS)
    .map(([name, value]) => {
      const text = typeof value === 'string' ? value : JSON.stringify(value);
      return {
        name: name.replace(/_/g, ' '),
        value: text.length > MAX_VALUE ? `${text.slice(0, MAX_VALUE)}…` : text,
      };
    });
}

export interface ApprovalCardProps {
  request: ApprovalRequest;
  logo?: string;
  onAnswer: (answer: ApprovalAnswer) => void;
}

/**
 * Asked before a connector changes something (send, create, delete…): what
 * will happen, with what, and three answers.
 */
export function ApprovalCard({request, logo, onAnswer}: ApprovalCardProps) {
  const rows = argumentRows(request.arguments);
  return (
    <View testID="approval-card" style={styles.card}>
      <View style={styles.head}>
        <AppLogo name={request.app} uri={logo} size={44} />
        <View style={styles.texts}>
          <Text variant="headline">
            {s.approvalTitle(request.app, request.action)}
          </Text>
          <Text variant="footnote" color="textSecondary">
            {s.approvalHint}
          </Text>
        </View>
      </View>
      {rows.length ? (
        <View style={styles.rows}>
          {rows.map(row => (
            <View key={row.name} style={styles.row}>
              <Text variant="caption" color="textSecondary">
                {row.name}
              </Text>
              <Text variant="callout" numberOfLines={4}>
                {row.value}
              </Text>
            </View>
          ))}
        </View>
      ) : null}
      <Button
        testID="approval-once"
        label={s.allowOnce}
        fullWidth
        onPress={() => onAnswer('once')}
      />
      <Button
        testID="approval-always"
        label={s.allowAlways}
        variant="secondary"
        fullWidth
        onPress={() => onAnswer('always')}
      />
      <Button
        testID="approval-deny"
        label={s.deny}
        variant="ghost"
        fullWidth
        onPress={() => onAnswer('deny')}
      />
    </View>
  );
}

const styles = StyleSheet.create(theme => ({
  card: {
    gap: theme.spacing.md,
  },
  head: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: theme.spacing.md,
  },
  texts: {
    flex: 1,
    gap: theme.spacing.xxs,
  },
  rows: {
    gap: theme.spacing.sm,
    padding: theme.spacing.md,
    borderRadius: theme.radii.md,
    backgroundColor: theme.colors.surface,
  },
  row: {
    gap: theme.spacing.xxs,
  },
}));
