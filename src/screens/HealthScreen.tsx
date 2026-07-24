// HealthScreen — 4 ChannelBadge components, one per Muse channel (TP9, AF7, AF8, TP10).
// Mirrors the macOS ChannelHealthBadge behavior. Stale sample (>2s) → orange.

import React from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ChannelBadge } from '../components/ChannelBadge';
import { useHealth } from '../hooks/useHealth';
import { useNow, relativeTime } from '../hooks/useNow';
import { colors, spacing, typography } from '../theme';

const CHANNELS = ['TP9', 'AF7', 'AF8', 'TP10'] as const;

export function HealthScreen() {
  const insets = useSafeAreaInsets();
  const { data, error, lastUpdate } = useHealth();
  const now = useNow(1000);

  // Index health rows by channel for stable ordering.
  const byChannel: Record<string, typeof data[number] | undefined> = {};
  data.forEach(c => { byChannel[c.channel] = c; });

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={[styles.container, { paddingTop: insets.top + spacing.md }]}
    >
      <Text style={styles.heading}>Channel Health</Text>
      <Text style={styles.subheading}>
        {data.length > 0
          ? `${data.length} channels · last update ${relativeTime(lastUpdate, now)}`
          : 'Waiting for first sample…'}
      </Text>

      {error ? (
        <View style={styles.errorBox}>
          <Text style={styles.errorText}>Health error: {error}</Text>
        </View>
      ) : null}

      <View style={styles.list}>
        {CHANNELS.map(name => (
          <ChannelBadge
            key={name}
            state={byChannel[name]}
            nowMs={now}
          />
        ))}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: colors.bg },
  container: { padding: spacing.lg, gap: spacing.lg, paddingBottom: spacing.xxl },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  subheading: { color: colors.textMuted, fontSize: typography.caption, marginTop: -spacing.sm },
  list: { gap: spacing.md },
  errorBox: { backgroundColor: colors.red + '22', borderColor: colors.red, borderWidth: 1, borderRadius: 8, padding: spacing.md },
  errorText: { color: colors.red, fontSize: typography.caption },
});
