// StaleIndicator — small orange badge that shows "no data Ns" when a stream goes quiet.
// Used by every screen that polls.

import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors, radius, spacing, typography } from '../theme';

interface Props {
  ageMs: number;
  thresholdMs: number;
  label?: string;
}

export function StaleIndicator({ ageMs, thresholdMs, label = 'no data' }: Props) {
  if (ageMs <= thresholdMs) return null;
  const seconds = Math.floor(ageMs / 1000);
  return (
    <View style={styles.container}>
      <View style={styles.dot} />
      <Text style={styles.text}>{label} {seconds}s</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.orange + '22',
    borderColor: colors.orange,
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: 4,
    alignSelf: 'flex-start',
  },
  dot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.orange },
  text: { color: colors.orange, fontSize: typography.micro, fontWeight: '700' },
});
