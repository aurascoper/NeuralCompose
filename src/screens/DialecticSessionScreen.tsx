// DialecticSessionScreen — the live dialectic session screen.
// Dedicated route; does not replace or modify the Journal.
// Uses existing visual language (colors, spacing, typography from theme.ts).
// Shows: session on/off, push-to-talk, phase, transcript, profile, outcome,
// tension, service chips, provenance badge, timing, developer diagnostics.

import React, { useState, useCallback } from 'react';
import {
  StyleSheet, Text, View, TouchableOpacity, ScrollView,
  Alert, Modal, TextInput, Switch,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  AudioModule, RecordingPresets, useAudioRecorder, useAudioRecorderState,
} from 'expo-audio';
import { colors, radius, spacing, typography } from '../theme';
import { useDialecticSession } from '../hooks/useDialecticSession';
import { PROFILES, PROFILE_IDS } from '../dialectic/profiles';
import { deriveRuntimePresentation } from '../runtime/identity';
import type { ProfileID } from '../dialectic/types';

export function DialecticSessionScreen() {
  const insets = useSafeAreaInsets();
  const { state, actions } = useDialecticSession();
  // Every runtime badge below derives from the resolved identity — no
  // hard-coded LOCAL / ON-DEVICE / READY / NO EGRESS strings (A2 delta).
  const runtimePresentation = state.identities
    ? deriveRuntimePresentation(state.identities.coherence)
    : null;
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY);
  const recorderState = useAudioRecorderState(recorder);
  const [showTextInject, setShowTextInject] = useState(false);
  const [textToInject, setTextToInject] = useState('');
  const [showDev, setShowDev] = useState(false);

  const handleStartSession = useCallback(async () => {
    try {
      const status = await AudioModule.requestRecordingPermissionsAsync();
      if (!status.granted) {
        Alert.alert('Microphone access denied', 'Voice input will not work. You can still use text injection.');
      }
    } catch {
      // Permission check is best-effort
    }
    await actions.startSession();
  }, [actions]);

  const handleStartRecording = useCallback(async () => {
    try {
      await recorder.prepareToRecordAsync();
      recorder.record();
      actions.startListening();
    } catch (e: any) {
      Alert.alert('Recording failed', String(e?.message ?? e));
    }
  }, [recorder, actions]);

  const handleStopRecording = useCallback(async () => {
    try {
      await recorder.stop();
      const uri = recorder.uri;
      if (uri) {
        // Recorder is stopped and released before STT begins (strict
        // mic/processing alternation). The temp clip is deleted by
        // prepareToRecordAsync reuse on the next turn; explicit deletion
        // is tracked as a READY task (needs expo-file-system).
        await actions.processRecording(uri);
      } else {
        Alert.alert('No recording captured', 'Try again, or use text injection.');
      }
    } catch (e: any) {
      Alert.alert('Could not stop recording', String(e?.message ?? e));
    }
  }, [recorder, actions]);

  const handleInjectText = useCallback(async () => {
    if (!textToInject.trim()) return;
    setShowTextInject(false);
    await actions.injectText(textToInject.trim());
    setTextToInject('');
  }, [textToInject, actions]);

  const recording = recorderState.isRecording;
  const canRecord = recorderState.canRecord;

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <ScrollView contentContainerStyle={styles.scroll}>
        <Text style={styles.heading}>Live Dialectic</Text>
        <Text style={styles.subheading}>
          {state.isSessionActive
            ? `${state.turns} turn${state.turns === 1 ? '' : 's'} completed`
            : 'Start a session to begin'}
        </Text>

        {/* Session Controls */}
        <View style={styles.card}>
          <View style={styles.buttonRow}>
            {!state.isSessionActive ? (
              <TouchableOpacity style={[styles.button, styles.buttonPrimary]} onPress={handleStartSession}>
                <Text style={styles.buttonText}>Start Session</Text>
              </TouchableOpacity>
            ) : (
              <>
                {!recording ? (
                  <TouchableOpacity
                    style={[
                      styles.button, styles.buttonAccent,
                      (!canRecord || !state.sttAvailable || state.phase !== 'ready') && styles.buttonDisabled,
                    ]}
                    onPress={handleStartRecording}
                    disabled={!canRecord || !state.sttAvailable || state.phase !== 'ready' || state.isTTSActive}
                  >
                    <Text style={styles.buttonText}>
                      {state.sttAvailable ? 'Push to Talk' : 'Mic off (no STT)'}
                    </Text>
                  </TouchableOpacity>
                ) : (
                  <TouchableOpacity style={[styles.button, styles.buttonStop]} onPress={handleStopRecording}>
                    <Text style={styles.buttonText}>Stop Recording</Text>
                  </TouchableOpacity>
                )}
                <TouchableOpacity
                  style={[styles.button, styles.buttonSecondary]}
                  onPress={() => setShowTextInject(true)}
                >
                  <Text style={styles.buttonText}>Inject Text</Text>
                </TouchableOpacity>
                <TouchableOpacity style={[styles.button, styles.buttonDanger]} onPress={actions.stopSession}>
                  <Text style={styles.buttonText}>Stop Session</Text>
                </TouchableOpacity>
              </>
            )}
          </View>
        </View>

        {/* Phase Indicator */}
        <View style={styles.card}>
          <Text style={styles.cardLabel}>PHASE</Text>
          <Text style={[styles.phaseText, state.phase === 'silent' && styles.phaseSilent]}>
            {state.phaseLabel}
          </Text>
          {state.error ? (
            <Text style={styles.errorText}>{state.error}</Text>
          ) : null}
        </View>

        {/* Transcript */}
        {state.transcript ? (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>HEARD</Text>
            <Text style={styles.transcriptText}>{state.transcript}</Text>
          </View>
        ) : null}

        {/* Last Spoken */}
        {state.lastSpoken ? (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>SPOKEN ({state.lastOutcome?.toUpperCase()})</Text>
            <Text style={styles.spokenText}>{state.lastSpoken}</Text>
          </View>
        ) : null}

        {/* Tension + Margin */}
        {state.lastOutcome ? (
          <View style={styles.metricsRow}>
            <View style={styles.metricCard}>
              <Text style={styles.metricLabel}>Tension</Text>
              <Text style={styles.metricValue}>{state.lastTension.toFixed(3)}</Text>
            </View>
            <View style={styles.metricCard}>
              <Text style={styles.metricLabel}>Margin</Text>
              <Text style={styles.metricValue}>{state.lastMargin.toFixed(3)}</Text>
            </View>
            <View style={styles.metricCard}>
              <Text style={styles.metricLabel}>Silence</Text>
              <Text style={styles.metricValue}>{state.consecutiveSilence}</Text>
            </View>
          </View>
        ) : null}

        {/* Profile Selector */}
        <View style={styles.card}>
          <Text style={styles.cardLabel}>PROFILE</Text>
          <View style={styles.profileRow}>
            {PROFILE_IDS.map((id) => (
              <TouchableOpacity
                key={id}
                style={[
                  styles.profileChip,
                  state.profile === id && styles.profileChipActive,
                ]}
                onPress={() => actions.setProfile(id)}
              >
                <Text
                  style={[
                    styles.profileChipText,
                    state.profile === id && styles.profileChipTextActive,
                  ]}
                >
                  {PROFILES[id].label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>
          <Text style={styles.profileSummary}>
            {PROFILES[state.profile].summary}
          </Text>
          {state.profile === 'reflective' ? (
            <Text style={styles.profileNote}>Witness backend not configured (Reflective core, Witness off)</Text>
          ) : null}
        </View>

        {/* Service Chips */}
        <View style={styles.card}>
          <Text style={styles.cardLabel}>SERVICES</Text>
          <View style={styles.serviceRow}>
            {state.serviceHealth.map((svc) => (
              <View key={svc.name} style={styles.serviceChip}>
                <View style={[
                  styles.serviceDot,
                  { backgroundColor: svc.status === 'ok' ? colors.green : svc.status === 'down' ? colors.red : colors.gray },
                ]} />
                <Text style={styles.serviceName}>{svc.name}</Text>
                <Text style={styles.serviceStatus}>{svc.status === 'ok' ? 'OK' : svc.status === 'down' ? 'DOWN' : '?'}</Text>
              </View>
            ))}
          </View>
          <View style={styles.serviceRow}>
            <Text style={styles.provenanceBadge}>
              {runtimePresentation ? runtimePresentation.provenanceBadge : state.provenanceLabel}
            </Text>
            <Text style={styles.embeddingMode}>
              Gates: {state.embeddingMode === 'mock' ? 'MOCK' : 'LIVE'}
            </Text>
          </View>
          {runtimePresentation ? (
            <View style={styles.serviceRow}>
              <Text style={styles.embeddingMode}>{runtimePresentation.egressLabel}</Text>
              <Text style={styles.embeddingMode}>{runtimePresentation.localityLabel}</Text>
              <Text style={styles.embeddingMode}>{runtimePresentation.readinessLabel}</Text>
            </View>
          ) : null}
          {state.embeddingMode === 'mock' ? (
            <Text style={styles.profileNote}>
              MOCK gates are not semantic decisions. Synthesis is disabled.
            </Text>
          ) : null}
        </View>

        {/* Timing */}
        {state.lastTiming ? (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>LAST TURN TIMING</Text>
            <Text style={styles.timingLine}>Total: {state.lastTiming.turnTotalMs}ms</Text>
            <Text style={styles.timingLine}>Coherence: {state.lastTiming.coherenceGenerateMs ?? 0}ms</Text>
            <Text style={styles.timingLine}>Displacement: {state.lastTiming.displacementGenerateMs ?? 0}ms</Text>
            <Text style={styles.timingLine}>Embedding: {state.lastTiming.embeddingMs ?? 0}ms</Text>
            <Text style={styles.timingLine}>TTS: {state.lastTiming.ttsDurationMs ?? 0}ms</Text>
          </View>
        ) : null}

        {/* Developer Drawer Toggle */}
        <TouchableOpacity
          style={[styles.button, styles.buttonSecondary, styles.devToggle]}
          onPress={() => setShowDev(!showDev)}
        >
          <Text style={styles.buttonText}>{showDev ? 'Hide' : 'Show'} Developer Info</Text>
        </TouchableOpacity>

        {showDev && state.lastCandidates ? (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>DEVELOPER — CANDIDATES</Text>
            {state.lastCandidates.map((c, i) => (
              <View key={i} style={styles.candidateRow}>
                <Text style={styles.candidateRole}>{c.roleID}</Text>
                <Text style={styles.candidatePotential}>{c.potential.toFixed(4)}</Text>
                <Text style={styles.candidateText}>{c.text}</Text>
              </View>
            ))}
            {state.lastDraw !== null ? (
              <Text style={styles.drawText}>RNG draw: {state.lastDraw.toFixed(6)}</Text>
            ) : null}
            <Text style={styles.drawText}>Prompts: {state.promptProfileLabel}</Text>
          </View>
        ) : null}

        {showDev && state.identities ? (
          <View style={styles.card}>
            <Text style={styles.cardLabel}>DEVELOPER — RUNTIME IDENTITY</Text>
            {(['coherence', 'displacement'] as const).map((role) => {
              const id = state.identities![role];
              return (
                <View key={role} style={styles.candidateRow}>
                  <Text style={styles.candidateRole}>{role}</Text>
                  <Text style={styles.drawText}>
                    requested: {id.requested.provider} / {id.requested.model.split('/').pop()}
                  </Text>
                  <Text style={styles.drawText}>
                    resolved: {id.resolved.model ? id.resolved.model.split('/').pop() : '(none)'}
                    {' · '}{id.resolved.modelMatch}{' · '}{id.resolved.readiness}
                  </Text>
                  <Text style={styles.drawText}>
                    locality: {id.resolved.locality} · endpoint: {id.resolved.endpointClass}
                  </Text>
                  <Text style={styles.drawText}>
                    prompt: {id.resolved.promptProfile} sha256:{id.resolved.promptSha256?.slice(0, 12) ?? '(missing)'}
                  </Text>
                  {id.failure ? (
                    <Text style={styles.drawText}>failure: {id.failure.category} — {id.failure.publicMessage}</Text>
                  ) : null}
                </View>
              );
            })}
            <Text style={styles.drawText}>witness: not configured — zero resolution work performed</Text>
          </View>
        ) : null}

        {/* Privacy Note — wording derives from observed locality, never a
            hard-coded provider claim (A2 delta). */}
        <Text style={styles.privacyNote}>
          {runtimePresentation
            ? (runtimePresentation.egressLabel === 'NO EGRESS'
                ? 'Verified: inference is local. No audio, text, or embeddings leave this device.'
                : `${runtimePresentation.egressLabel} — locality has not been verified as local. ` +
                  'Do not assume audio or text stays on this device.')
            : 'Locality unverified — runs a readiness check when a session starts.'}
          {' '}EEG wind: neutral / unavailable.
        </Text>
      </ScrollView>

      {/* Text Injection Modal */}
      <Modal
        visible={showTextInject}
        transparent={true}
        animationType="fade"
        onRequestClose={() => setShowTextInject(false)}
      >
        <View style={styles.modalOverlay}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>Inject Text (STT bypass)</Text>
            <TextInput
              style={styles.modalInput}
              value={textToInject}
              onChangeText={setTextToInject}
              placeholder="Type what was heard..."
              placeholderTextColor={colors.textDim}
              multiline
              autoFocus
            />
            <View style={styles.modalButtons}>
              <TouchableOpacity
                style={[styles.button, styles.buttonSecondary]}
                onPress={() => setShowTextInject(false)}
              >
                <Text style={styles.buttonText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.button, styles.buttonPrimary]}
                onPress={handleInjectText}
                disabled={!textToInject.trim()}
              >
                <Text style={styles.buttonText}>Process Turn</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg, padding: spacing.lg },
  scroll: { gap: spacing.md, paddingBottom: spacing.xxl },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  subheading: { color: colors.textMuted, fontSize: typography.caption, marginTop: -spacing.sm },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    gap: spacing.sm,
  },
  cardLabel: {
    color: colors.accent,
    fontSize: typography.micro,
    fontWeight: '700',
    letterSpacing: 1.2,
  },
  buttonRow: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap' },
  button: {
    borderRadius: radius.sm,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    flex: 1,
    alignItems: 'center',
    minWidth: 100,
  },
  buttonPrimary: { backgroundColor: colors.accentDim },
  buttonAccent: { backgroundColor: colors.accent },
  buttonSecondary: { backgroundColor: colors.surfaceAlt },
  buttonStop: { backgroundColor: colors.orange },
  buttonDanger: { backgroundColor: colors.red },
  buttonDisabled: { opacity: 0.4 },
  buttonText: { color: colors.white, fontSize: typography.caption, fontWeight: '700' },
  phaseText: { color: colors.text, fontSize: typography.heading, fontWeight: '600' },
  phaseSilent: { color: colors.orange, fontStyle: 'italic' },
  errorText: { color: colors.red, fontSize: typography.caption, marginTop: spacing.xs },
  transcriptText: { color: colors.text, fontSize: typography.body },
  spokenText: { color: colors.text, fontSize: typography.body, lineHeight: 20 },
  metricsRow: { flexDirection: 'row', gap: spacing.sm },
  metricCard: {
    flex: 1,
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    alignItems: 'center',
  },
  metricLabel: { color: colors.textMuted, fontSize: typography.micro },
  metricValue: { color: colors.text, fontSize: typography.heading, fontWeight: '700', fontVariant: ['tabular-nums'] },
  profileRow: { flexDirection: 'row', gap: spacing.xs },
  profileChip: {
    backgroundColor: colors.surfaceAlt,
    borderRadius: radius.pill,
    paddingVertical: spacing.xs,
    paddingHorizontal: spacing.md,
    borderWidth: 1,
    borderColor: colors.border,
  },
  profileChipActive: {
    backgroundColor: colors.accent + '22',
    borderColor: colors.accent,
  },
  profileChipText: { color: colors.textMuted, fontSize: typography.caption, fontWeight: '600' },
  profileChipTextActive: { color: colors.accent },
  profileSummary: { color: colors.textMuted, fontSize: typography.caption, marginTop: spacing.xs },
  profileNote: { color: colors.orange, fontSize: typography.micro, fontStyle: 'italic' },
  serviceRow: { flexDirection: 'row', gap: spacing.md, alignItems: 'center', flexWrap: 'wrap' },
  serviceChip: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  serviceDot: { width: 8, height: 8, borderRadius: 4 },
  serviceName: { color: colors.text, fontSize: typography.micro, fontWeight: '600' },
  serviceStatus: { color: colors.textMuted, fontSize: typography.micro },
  provenanceBadge: {
    color: colors.accent,
    fontSize: typography.micro,
    fontWeight: '700',
    letterSpacing: 1,
  },
  embeddingMode: {
    color: colors.orange,
    fontSize: typography.micro,
    fontWeight: '600',
  },
  timingLine: { color: colors.textMuted, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  devToggle: { marginTop: spacing.xs },
  candidateRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: spacing.sm,
    paddingVertical: spacing.xs,
    borderTopWidth: 1,
    borderTopColor: colors.border,
  },
  candidateRole: { color: colors.accent, fontSize: typography.micro, fontWeight: '700', width: 100 },
  candidatePotential: { color: colors.textMuted, fontSize: typography.micro, fontVariant: ['tabular-nums'], width: 60 },
  candidateText: { color: colors.text, fontSize: typography.micro, flex: 1 },
  drawText: { color: colors.textDim, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  privacyNote: { color: colors.textDim, fontSize: 10, textAlign: 'center', padding: spacing.sm },
  modalOverlay: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.7)',
    justifyContent: 'center',
    padding: spacing.xl,
  },
  modalCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: spacing.lg,
    gap: spacing.md,
  },
  modalTitle: { color: colors.text, fontSize: typography.heading, fontWeight: '700' },
  modalInput: {
    color: colors.text,
    fontSize: typography.body,
    minHeight: 80,
    backgroundColor: colors.bg,
    borderRadius: radius.sm,
    padding: spacing.sm,
    textAlignVertical: 'top',
  },
  modalButtons: { flexDirection: 'row', gap: spacing.sm },
});