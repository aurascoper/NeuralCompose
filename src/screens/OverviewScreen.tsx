// OverviewScreen — top of the app. Privacy badge + diagnostics panel.
// Shows: packets received/dropped, jitter, last heartbeat (relative), bound port, interface name.
// If lastHeartbeat > 5s old, the StaleIndicator turns orange.

import React, { useEffect, useState } from 'react';
import { RefreshControl, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { PrivacyBadge } from '../components/PrivacyBadge';
import { StaleIndicator } from '../components/StaleIndicator';
import { useDiagnostics } from '../hooks/useDiagnostics';
import { usePipelineMode } from '../hooks/usePipelineMode';
import { useNow, relativeTime } from '../hooks/useNow';
import { colors, radius, spacing, typography } from '../theme';
import { STALE } from '../config';

export function OverviewScreen() {
  const insets = useSafeAreaInsets();
  const diag = useDiagnostics();
  const mode = usePipelineMode();
  const now = useNow(1000);
  const [refreshing, setRefreshing] = useState(false);

  const onRefresh = () => {
    setRefreshing(true);
    Promise.all([diag.data, mode.data]).finally(() => setRefreshing(false));
  };

  const heartbeatMs = diag.data ? now - Date.parse(diag.data.lastHeartbeat) : Infinity;
  const heartbeatStale = heartbeatMs > STALE.heartbeat;

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={[styles.container, { paddingTop: insets.top + spacing.md }]}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={onRefresh}
          tintColor={colors.text}
        />
      }
    >
      <Text style={styles.heading}>Overview</Text>
      <Text style={styles.subheading}>NeuralCompose pipeline status</Text>

      <View style={styles.section}>
        <PrivacyBadge mode={mode.data} />
      </View>

      {diag.error ? (
        <View style={[styles.section, styles.errorBox]}>
          <Text style={styles.errorText}>Diagnostics error: {diag.error}</Text>
        </View>
      ) : null}

      <View style={styles.section}>
        <View style={styles.diagHeader}>
          <Text style={styles.sectionTitle}>Diagnostics</Text>
          {heartbeatStale ? <StaleIndicator ageMs={heartbeatMs} thresholdMs={STALE.heartbeat} label="no heartbeat" /> : null}
        </View>
        <View style={styles.diagCard}>
          <DiagRow label="Transport" value={diag.data?.transport ?? '—'} />
          <DiagRow label="Sample rate" value={diag.data ? `${diag.data.sampleRate.toFixed(0)} Hz` : '—'} />
          <DiagRow label="Packets received" value={diag.data ? diag.data.packetsReceived.toLocaleString() : '—'} mono />
          <DiagRow label="Packets dropped" value={diag.data ? diag.data.packetsDropped.toLocaleString() : '—'} mono />
          <DiagRow label="Packet loss" value={diag.data?.packetLossEstimate != null ? `${(diag.data.packetLossEstimate * 100).toFixed(2)}%` : '—'} />
          <DiagRow label="Jitter" value={diag.data ? `${diag.data.packetJitterMillis.toFixed(2)} ms` : '—'} mono />
          <DiagRow label="Last inter-arrival" value={diag.data ? `${diag.data.lastInterArrivalMillis.toFixed(2)} ms` : '—'} mono />
          <DiagRow label="Last heartbeat" value={diag.data ? relativeTime(diag.data.lastHeartbeat, now) : '—'} />
          <DiagRow label="Bound port" value={diag.data ? String(diag.data.boundPort) : '—'} mono />
          <DiagRow label="Interface" value={diag.data?.localInterfaceName ?? '—'} mono />
        </View>
      </View>

      <View style={[styles.section, styles.footer]}>
        <Text style={styles.footerText}>
          {diag.data
            ? `Polling every 1s · last update ${relativeTime(diag.lastUpdate, now)}`
            : 'Connecting to pipeline…'}
        </Text>
      </View>
    </ScrollView>
  );
}

function DiagRow({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <View style={styles.row}>
      <Text style={styles.rowLabel}>{label}</Text>
      <Text style={[styles.rowValue, mono && styles.mono]}>{value}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: { flex: 1, backgroundColor: colors.bg },
  container: { padding: spacing.lg, paddingBottom: spacing.xxl, gap: spacing.lg },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  subheading: { color: colors.textMuted, fontSize: typography.caption, marginTop: -spacing.sm },
  section: { gap: spacing.sm },
  sectionTitle: { color: colors.text, fontSize: typography.heading, fontWeight: '600' },
  diagHeader: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  diagCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  row: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  rowLabel: { color: colors.textMuted, fontSize: typography.caption, flex: 1 },
  rowValue: { color: colors.text, fontSize: typography.caption, fontWeight: '600', textAlign: 'right' },
  mono: { fontVariant: ['tabular-nums'] },
  errorBox: { backgroundColor: colors.red + '22', borderColor: colors.red, borderWidth: 1, borderRadius: radius.md, padding: spacing.md },
  errorText: { color: colors.red, fontSize: typography.caption },
  footer: { alignItems: 'center' },
  footerText: { color: colors.textDim, fontSize: typography.micro, textAlign: 'center' },
});
