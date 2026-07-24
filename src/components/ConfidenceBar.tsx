// ConfidenceBar — horizontal bar showing 0..1 confidence for a single intent class.
// Used by ClassifierScreen for the dominant prediction and the 5-class distribution.

import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors, radius, spacing, typography } from '../theme';

interface Props {
  label: string;
  value: number;        // 0..1
  highlight?: boolean;
}

export function ConfidenceBar({ label, value, highlight = false }: Props) {
  const pct = Math.max(0, Math.min(1, value));
  const fill = highlight ? colors.accent : colors.blue;
  return (
    <View style={styles.row}>
      <Text style={[styles.label, highlight && styles.labelHighlight]}>{label}</Text>
      <View style={styles.track}>
        <View style={[styles.fill, { width: `${pct * 100}%`, backgroundColor: fill }]} />
      </View>
      <Text style={[styles.value, highlight && { color: colors.accent }]}>
        {(pct * 100).toFixed(0)}%
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.xs,
  },
  label: {
    color: colors.textMuted,
    fontSize: typography.caption,
    fontWeight: '500',
    width: 110,
  },
  labelHighlight: { color: colors.text, fontWeight: '700' },
  track: {
    flex: 1,
    height: 14,
    backgroundColor: colors.surfaceAlt,
    borderRadius: radius.sm,
    overflow: 'hidden',
  },
  fill: { height: '100%', borderRadius: radius.sm },
  value: {
    color: colors.textMuted,
    fontSize: typography.caption,
    fontVariant: ['tabular-nums'],
    width: 48,
    textAlign: 'right',
  },
});
