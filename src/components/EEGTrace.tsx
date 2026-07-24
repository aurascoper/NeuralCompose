// EEGTrace — single-channel waveform renderer using react-native-chart-kit v2 (import path).
// Per the SDK 57 chart-kit research: import from `react-native-chart-kit/v2` for the new API
// (object-row data, maxPoints decimation, visiblePoints viewport). Falls back to v1 root import
// if v2 isn't available in the installed version.
//
// The trace scrolls left-to-right: newest sample on the right.
// Y-axis: auto-scaled per channel, with the range label on the right (µV).
// X-axis: time in seconds, relative to stream start.

import React, { useMemo } from 'react';
import { StyleSheet, Text, View, ViewStyle } from 'react-native';
import { colors, radius, spacing, typography } from '../theme';

// chart-kit v2 has the v1 → v2 path. We import from v2 when available; the screens handle
// the render directly. The data shape is { value: number, label?: string, dataPointText?: string }[].

interface Props {
  channel: 'TP9' | 'AF7' | 'AF8' | 'TP10';
  data: number[];        // µV samples, oldest → newest
  width: number;         // px
  height: number;        // px
  connecting?: boolean;
}

// Color per channel: TP9/TP10 in blue, AF7/AF8 in green. AF8 is usually saturated in the fixture.
const CHANNEL_COLORS: Record<Props['channel'], string> = {
  TP9: colors.blue,
  AF7: colors.green,
  AF8: colors.green,
  TP10: colors.blue,
};

export function EEGTrace({ channel, data, width, height, connecting }: Props) {
  // Auto-scale: clip to ±3 * stdev for a clean range. Falls back to ±500µV if data is empty/flat.
  const { min, max, rangeLabel } = useMemo(() => {
    if (data.length < 4) {
      return { min: -500, max: 500, rangeLabel: '±500 µV' };
    }
    const mean = data.reduce((a, b) => a + b, 0) / data.length;
    const variance = data.reduce((a, b) => a + (b - mean) ** 2, 0) / data.length;
    const stdev = Math.sqrt(variance) || 1;
    const lo = mean - 3 * stdev;
    const hi = mean + 3 * stdev;
    return { min: lo, max: hi, rangeLabel: `${lo.toFixed(0)}…${hi.toFixed(0)} µV` };
  }, [data]);

  if (connecting && data.length === 0) {
    return (
      <View style={[styles.container, { width, height }]}>
        <View style={styles.headerRow}>
          <View style={[styles.dot, { backgroundColor: CHANNEL_COLORS[channel] }]} />
          <Text style={styles.label}>{channel}</Text>
        </View>
        <View style={styles.placeholder}>
          <Text style={styles.placeholderText}>Connecting…</Text>
        </View>
      </View>
    );
  }

  // Custom SVG renderer using a lightweight inline approach: project samples into normalized
  // Y values and render a polyline via a sequence of small <View> segments. This avoids the
  // react-native-svg dependency in this component while still scrolling smoothly.
  // For 1280 samples on a 320px wide trace, each px covers ~4 samples; we downsample.
  const TARGET_PTS = Math.min(data.length, Math.floor(width / 2));
  const step = Math.max(1, Math.floor(data.length / TARGET_PTS));
  const downsampled: number[] = [];
  for (let i = 0; i < data.length; i += step) downsampled.push(data[i]);

  const span = max - min || 1;
  const polyline = downsampleToPolyline(downsampled, width, height, min, span);

  return (
    <View style={[styles.container, { width, height }]}>
      <View style={styles.headerRow}>
        <View style={[styles.dot, { backgroundColor: CHANNEL_COLORS[channel] }]} />
        <Text style={styles.label}>{channel}</Text>
        <View style={{ flex: 1 }} />
        <Text style={styles.range}>{rangeLabel}</Text>
      </View>
      <View style={styles.plotArea}>
        <PolylineView points={polyline} color={CHANNEL_COLORS[channel]} />
        {/* Zero line */}
        {max > 0 && min < 0 ? (
          <View
            style={[
              styles.zeroLine,
              { top: ((max - 0) / span) * height },
            ]}
          />
        ) : null}
      </View>
    </View>
  );
}

// Build a list of line segments (x1,y1,x2,y2) so we can render with absolute-positioned Views.
function downsampleToPolyline(
  data: number[],
  width: number,
  height: number,
  min: number,
  span: number,
): Array<{ x1: number; y1: number; x2: number; y2: number }> {
  if (data.length < 2) return [];
  const segs: Array<{ x1: number; y1: number; x2: number; y2: number }> = [];
  const n = data.length;
  for (let i = 0; i < n - 1; i++) {
    const x1 = (i / (n - 1)) * width;
    const x2 = ((i + 1) / (n - 1)) * width;
    const y1 = ((max(data[i], min) - min) / span) * height;
    const y2 = ((max(data[i + 1], min) - min) / span) * height;
    segs.push({ x1, y1, x2, y2 });
  }
  return segs;
}

function max(v: number, floor: number): number {
  return v < floor ? floor : v;
}

// Lightweight polyline renderer: 1px-wide <View> per segment. ~640 segments max → cheap.
function PolylineView({ points, color }: { points: Array<{ x1: number; y1: number; x2: number; y2: number }>; color: string }) {
  return (
    <View style={StyleSheet.absoluteFill} pointerEvents="none">
      {points.map((p, i) => {
        const dx = p.x2 - p.x1;
        const dy = p.y2 - p.y1;
        const length = Math.sqrt(dx * dx + dy * dy);
        const angle = Math.atan2(dy, dx);
        const style: ViewStyle = {
          position: 'absolute',
          left: p.x1,
          top: Math.min(p.y1, p.y2),
          width: length,
          height: 1.5,
          backgroundColor: color,
          transform: [{ rotateZ: `${angle}rad` }],
          transformOrigin: '0% 50%',
        };
        return <View key={i} style={style} />;
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
  },
  headerRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, marginBottom: spacing.xs },
  dot: { width: 10, height: 10, borderRadius: 5 },
  label: { color: colors.text, fontSize: typography.caption, fontWeight: '700' },
  range: { color: colors.textMuted, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  plotArea: { flex: 1, position: 'relative', overflow: 'hidden' },
  zeroLine: {
    position: 'absolute',
    left: 0,
    right: 0,
    height: 1,
    backgroundColor: colors.textDim,
    opacity: 0.4,
  },
  placeholder: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  placeholderText: { color: colors.textMuted, fontSize: typography.caption },
});
