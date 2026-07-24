// ClassifierScreen — large predicted intent + confidence bar + full 5-class distribution.
// If classifier idle for >5s, dim the screen and show "Classifier idle."

import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ConfidenceBar } from '../components/ConfidenceBar';
import { StaleIndicator } from '../components/StaleIndicator';
import { useClassifier } from '../hooks/useClassifier';
import { useNow } from '../hooks/useNow';
import type { IntentLabel } from '../types/api';
import { colors, radius, spacing, typography } from '../theme';
import { STALE } from '../config';

const INTENT_LABELS: Record<IntentLabel, string> = {
  rest: 'Rest',
  jawClench: 'Jaw Clench',
  singleBlink: 'Single Blink',
  doubleBlink: 'Double Blink',
  select: 'Select',
};

const INTENT_ORDER: IntentLabel[] = ['rest', 'jawClench', 'singleBlink', 'doubleBlink', 'select'];

export function ClassifierScreen() {
  const insets = useSafeAreaInsets();
  const { data, lastUpdate } = useClassifier();
  const now = useNow(1000);

  const ageMs = lastUpdate === 0 ? Infinity : now - lastUpdate;
  const isIdle = ageMs > STALE.classifier;

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={[styles.container, { paddingTop: insets.top + spacing.md, opacity: isIdle ? 0.4 : 1 }]}
    >
      <View style={styles.header}>
        <Text style={styles.heading}>Classifier</Text>
        {isIdle ? <StaleIndicator ageMs={ageMs} thresholdMs={STALE.classifier} label="classifier idle" /> : null}
      </View>

      <View style={styles.heroCard}>
        <Text style={styles.heroLabel}>Predicted intent</Text>
        <Text style={styles.heroIntent}>
          {data ? INTENT_LABELS[data.intent] : '—'}
        </Text>
        {data ? (
          <View style={styles.confidenceBlock}>
            <Text style={styles.confidenceNumber}>{(data.confidence * 100).toFixed(0)}%</Text>
            <View style={styles.confidenceTrack}>
              <View
                style={[
                  styles.confidenceFill,
                  { width: `${Math.min(100, data.confidence * 100)}%` },
                ]}
              />
            </View>
            <Text style={styles.confidenceCaption}>window #{data.windowSequence.toLocaleString()} · t={data.endTimestamp.toFixed(1)}s</Text>
          </View>
        ) : (
          <Text style={styles.heroWaiting}>waiting for first prediction…</Text>
        )}
      </View>

      <View style={styles.distCard}>
        <Text style={styles.sectionTitle}>Distribution</Text>
        {data
          ? INTENT_ORDER.map(label => (
              <ConfidenceBar
                key={label}
                label={INTENT_LABELS[label]}
                value={data.distribution[label]}
                highlight={label === data.intent}
              />
            ))
          : INTENT_ORDER.map(label => (
              <ConfidenceBar key={label} label={INTENT_LABELS[label]} value={0} />
            ))}
      </View>

      {isIdle ? (
        <View style={styles.idleBanner}>
          <Text style={styles.idleText}>Classifier idle — no prediction in {Math.floor(ageMs / 1000)}s</Text>
        </View>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: colors.bg },
  container: { padding: spacing.lg, gap: spacing.lg, paddingBottom: spacing.xxl },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  heroCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.xl,
    alignItems: 'center',
    gap: spacing.md,
  },
  heroLabel: { color: colors.textMuted, fontSize: typography.caption, textTransform: 'uppercase', letterSpacing: 1 },
  heroIntent: { color: colors.accent, fontSize: 36, fontWeight: '800', textAlign: 'center' },
  heroWaiting: { color: colors.textMuted, fontSize: typography.body, fontStyle: 'italic' },
  confidenceBlock: { width: '100%', alignItems: 'center', gap: spacing.sm },
  confidenceNumber: { color: colors.text, fontSize: typography.title, fontWeight: '700', fontVariant: ['tabular-nums'] },
  confidenceTrack: {
    width: '100%',
    height: 18,
    backgroundColor: colors.surfaceAlt,
    borderRadius: radius.sm,
    overflow: 'hidden',
  },
  confidenceFill: { height: '100%', backgroundColor: colors.accent },
  confidenceCaption: { color: colors.textDim, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  distCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    gap: spacing.xs,
  },
  sectionTitle: { color: colors.text, fontSize: typography.heading, fontWeight: '600', marginBottom: spacing.sm },
  idleBanner: { backgroundColor: colors.orange + '22', borderColor: colors.orange, borderWidth: 1, borderRadius: radius.md, padding: spacing.md, alignItems: 'center' },
  idleText: { color: colors.orange, fontSize: typography.caption, fontWeight: '600' },
});
