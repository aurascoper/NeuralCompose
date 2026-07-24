// ChannelBadge — single channel health indicator (TP9 / AF7 / AF8 / TP10).
// Mirrors the macOS ChannelHealthBadge behavior.
// Stale sample (>2s) → orange "stale" sublabel.

import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors, radius, spacing, typography } from '../theme';
import type { ChannelHealthState, ChannelStatus } from '../types/api';

const STATUS_COLORS: Record<ChannelStatus, string> = {
  healthy: colors.green,
  saturated: colors.red,
  dead: colors.gray,
  unknown: colors.blue,
};

const STATUS_LABEL: Record<ChannelStatus, string> = {
  healthy: 'Healthy',
  saturated: 'Saturated',
  dead: 'Dead',
  unknown: 'Unknown',
};

interface Props {
  state: ChannelHealthState | null | undefined;
  nowMs: number;
  staleMs?: number;
}

export function ChannelBadge({ state, nowMs, staleMs = 2000 }: Props) {
  if (!state) {
    return (
      <View style={styles.container}>
        <Text style={styles.name}>—</Text>
        <Text style={styles.meta}>waiting</Text>
      </View>
    );
  }
  const ageMs = nowMs - state.lastSampleWallClock * 1000;
  const isStale = ageMs > staleMs;
  const statusColor = isStale ? colors.orange : STATUS_COLORS[state.status];
  return (
    <View style={styles.container}>
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: statusColor }]} />
        <Text style={styles.name}>{state.channel}</Text>
        <View style={[styles.pill, { borderColor: statusColor }]}>
          <Text style={[styles.pillText, { color: statusColor }]}>
            {isStale ? 'STALE' : STATUS_LABEL[state.status].toUpperCase()}
          </Text>
        </View>
      </View>
      <View style={styles.metaRow}>
        <Text style={styles.meta}>RMS {state.rms.toFixed(1)} µV</Text>
        <Text style={styles.metaDot}>·</Text>
        <Text style={styles.meta}>{state.samples.toLocaleString()} samples</Text>
        <Text style={styles.metaDot}>·</Text>
        <Text style={styles.meta}>t={state.timestamp.toFixed(1)}s</Text>
      </View>
      {isStale ? (
        <Text style={styles.staleText}>last sample {Math.floor(ageMs / 1000)}s ago</Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    padding: spacing.lg,
    borderWidth: 1,
    borderColor: colors.border,
  },
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  dot: { width: 12, height: 12, borderRadius: 6 },
  name: { color: colors.text, fontSize: typography.heading, fontWeight: '700', flex: 1 },
  pill: {
    borderRadius: radius.pill,
    borderWidth: 1,
    paddingHorizontal: spacing.md,
    paddingVertical: 2,
  },
  pillText: { fontSize: typography.micro, fontWeight: '700', letterSpacing: 0.5 },
  metaRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, marginTop: spacing.sm },
  meta: { color: colors.textMuted, fontSize: typography.caption },
  metaDot: { color: colors.textDim, fontSize: typography.caption },
  staleText: { color: colors.orange, fontSize: typography.micro, marginTop: spacing.xs },
});
