// PrivacyBadge — the top-of-OverviewScreen banner that shows the active source,
// transport detail, and whether the pipeline is fully live.
// Mirrors the macOS `PrivacyBanner`.

import React from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { colors, radius, spacing, typography } from '../theme';
import type { PipelineMode } from '../types/api';

interface Props {
  mode: PipelineMode | null;
}

export function PrivacyBadge({ mode }: Props) {
  if (!mode) {
    return (
      <View style={[styles.container, styles.pending]}>
        <Text style={styles.title}>Loading pipeline…</Text>
      </View>
    );
  }
  const liveLabel = mode.isFullyLive ? 'FULLY LIVE' : 'SUBSTITUTED';
  const liveColor = mode.isFullyLive ? colors.green : colors.orange;
  return (
    <View style={styles.container}>
      <View style={styles.row}>
        <View style={[styles.dot, { backgroundColor: liveColor }]} />
        <Text style={styles.title}>{mode.sourceProfile}</Text>
      </View>
      <Text style={styles.detail}>{mode.transportDetail}</Text>
      <View style={styles.metaRow}>
        <View style={[styles.chip, { borderColor: liveColor }]}>
          <Text style={[styles.chipText, { color: liveColor }]}>{liveLabel}</Text>
        </View>
        <View style={styles.chip}>
          <Text style={styles.chipText}>classifier: {mode.classifier}</Text>
        </View>
        <View style={styles.chip}>
          <Text style={styles.chipText}>predictor: {mode.predictor}</Text>
        </View>
      </View>
      {mode.substitutionSummary ? (
        <Text style={styles.substitution}>{mode.substitutionSummary}</Text>
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
  pending: { opacity: 0.6 },
  row: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  dot: { width: 10, height: 10, borderRadius: 5 },
  title: { color: colors.text, fontSize: typography.heading, fontWeight: '600' },
  detail: { color: colors.textMuted, fontSize: typography.caption, marginTop: spacing.xs },
  metaRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, marginTop: spacing.md },
  chip: {
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: spacing.md,
    paddingVertical: 4,
  },
  chipText: { color: colors.textMuted, fontSize: typography.micro, fontWeight: '600' },
  substitution: { color: colors.orange, fontSize: typography.micro, marginTop: spacing.sm },
});
