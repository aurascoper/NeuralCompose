// EEGScreen — four stacked waveforms (TP9, AF7, AF8, TP10) scrolling left-to-right.
// Custom polyline renderer (see EEGTrace.tsx) — no react-native-svg, no chart-kit.
// If WebSocket is disconnected, freeze the last data and show a "Stream disconnected" banner.

import React from 'react';
import { ScrollView, StyleSheet, Text, View, useWindowDimensions } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { EEGTrace } from '../components/EEGTrace';
import { useEEGStream } from '../hooks/useEEGStream';
import { presentStream, type StreamTone } from '../hooks/streamPresentation';
import { useNow } from '../hooks/useNow';
import { STALE } from '../config';
import { colors, radius, spacing, typography } from '../theme';

const CHANNELS = ['TP9', 'AF7', 'AF8', 'TP10'] as const;

const TONE_COLORS: Record<StreamTone, string> = {
  ok: colors.green,
  stale: colors.orange,
  connecting: colors.orange,
  down: colors.red,
};

export function EEGScreen() {
  const insets = useSafeAreaInsets();
  const { width } = useWindowDimensions();
  const traceWidth = width - spacing.lg * 2 - spacing.md * 2; // outer padding + card padding
  const traceHeight = 96;
  const { buffer, status, lastUpdate } = useEEGStream();
  const now = useNow(1000);

  // Age of the newest RECEIVED sample — Infinity until the first one arrives.
  const sampleAgeMs = lastUpdate > 0 ? Math.max(0, now - lastUpdate) : Infinity;
  const view = presentStream(status, sampleAgeMs, STALE.channelSample);

  const connecting = status === 'connecting';
  const disconnected = status === 'closed' || status === 'error';

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={[styles.container, { paddingTop: insets.top + spacing.md }]}
    >
      <View style={styles.header}>
        <Text style={styles.heading}>EEG Stream</Text>
        <View style={styles.statusPill}>
          <View style={[styles.statusDot, { backgroundColor: TONE_COLORS[view.tone] }]} />
          <Text style={styles.statusText}>{view.label}</Text>
        </View>
      </View>

      <Text style={styles.subheading}>
        {buffer.received > 0
          ? `${buffer.received.toLocaleString()} samples received`
          : 'Waiting for first sample…'}
      </Text>

      {view.banner ? (
        <View style={[styles.banner, view.tone === 'stale' && styles.bannerStale]}>
          <Text style={[styles.bannerText, view.tone === 'stale' && styles.bannerTextStale]}>{view.banner}</Text>
        </View>
      ) : null}

      <View style={styles.traceList}>
        {CHANNELS.map(name => (
          <EEGTrace
            key={name}
            channel={name}
            data={buffer.channels[name === 'TP9' ? 0 : name === 'AF7' ? 1 : name === 'AF8' ? 2 : 3]}
            width={traceWidth}
            height={traceHeight}
            connecting={connecting && buffer.received === 0}
          />
        ))}
      </View>

      <View style={styles.footer}>
        <Text style={styles.footerText}>
          {lastUpdate > 0 ? `last sample ${Math.floor(sampleAgeMs / 1000)}s ago · 5s window · ~30 fps render` : 'idle'}
        </Text>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: colors.bg },
  container: { padding: spacing.lg, gap: spacing.lg, paddingBottom: spacing.xxl },
  header: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  subheading: { color: colors.textMuted, fontSize: typography.caption, marginTop: -spacing.sm },
  statusPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.surface,
    borderRadius: radius.pill,
    borderWidth: 1,
    borderColor: colors.border,
    paddingHorizontal: spacing.md,
    paddingVertical: 4,
  },
  statusDot: { width: 8, height: 8, borderRadius: 4 },
  statusText: { color: colors.text, fontSize: typography.micro, fontWeight: '700', letterSpacing: 0.5 },
  banner: {
    backgroundColor: colors.red + '22',
    borderColor: colors.red,
    borderWidth: 1,
    borderRadius: radius.md,
    padding: spacing.md,
  },
  bannerText: { color: colors.red, fontSize: typography.caption, fontWeight: '600', textAlign: 'center' },
  bannerStale: { backgroundColor: colors.orange + '22', borderColor: colors.orange },
  bannerTextStale: { color: colors.orange },
  traceList: { gap: spacing.sm },
  footer: { alignItems: 'center' },
  footerText: { color: colors.textDim, fontSize: typography.micro, textAlign: 'center' },
});
