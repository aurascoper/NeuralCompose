// DreamJournalScreen — text + voice dream report entry, local AsyncStorage.
// Voice uses expo-audio (SDK 57 replacement for expo-av).
// Local-only. No M4 sync in v0.1 (per Part 5.5 + Part 10 of the prompt).
//
// Permissions: RECORD_AUDIO is declared in app.json android.permissions.
// On Expo Go, the prompt comes up automatically when you call prepareToRecordAsync().

import React, { useCallback, useEffect, useState } from 'react';
import { Alert, FlatList, StyleSheet, Text, TextInput, TouchableOpacity, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {
  AudioModule,
  RecordingPresets,
  useAudioPlayer,
  useAudioRecorder,
  useAudioRecorderState,
} from 'expo-audio';
import { useFocusEffect } from '@react-navigation/native';
import { addEntry, deleteEntry, listEntries, updateEntry, type DreamEntry } from '../storage/DreamJournal';
import { synthesizeDream } from '../api/LLMClient';
import { colors, radius, spacing, typography } from '../theme';
import { useNow, relativeTime } from '../hooks/useNow';

function formatDuration(ms: number): string {
  const s = Math.floor(ms / 1000);
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
}

function AudioPlayer({ uri }: { uri: string }) {
  const player = useAudioPlayer(uri);
  const [playing, setPlaying] = useState(false);
  return (
    <TouchableOpacity
      onPress={() => {
        if (playing) {
          player.pause();
          setPlaying(false);
        } else {
          player.play();
          setPlaying(true);
        }
      }}
      style={styles.playButton}
    >
      <Text style={styles.playText}>{playing ? '■ Stop' : '▶ Play'}</Text>
    </TouchableOpacity>
  );
}

export function DreamJournalScreen() {
  const insets = useSafeAreaInsets();
  const [text, setText] = useState('');
  const [entries, setEntries] = useState<DreamEntry[]>([]);
  const recorder = useAudioRecorder(RecordingPresets.HIGH_QUALITY);
  const recorderState = useAudioRecorderState(recorder);
  const now = useNow(1000);

  const refresh = useCallback(async () => {
    const e = await listEntries();
    setEntries(e);
  }, []);

  // Refresh on focus so deletions from a previous visit show up.
  useFocusEffect(useCallback(() => { refresh(); }, [refresh]));

  // One-time permission request on mount.
  useEffect(() => {
    (async () => {
      try {
        const status = await AudioModule.requestRecordingPermissionsAsync();
        if (!status.granted) {
          Alert.alert('Microphone access denied', 'Voice entries will not work without microphone permission. Text entries are still available.');
        }
      } catch {
        // Older SDKs expose getRecordingPermissionsAsync — we ignore here.
      }
    })();
  }, []);

  const startRecording = async () => {
    try {
      await recorder.prepareToRecordAsync();
      recorder.record();
    } catch (e: any) {
      Alert.alert('Recording failed', String(e?.message ?? e));
    }
  };

  const stopRecording = async () => {
    try {
      await recorder.stop();
      const uri = recorder.uri;
      if (uri) {
        await addEntry({
          text,
          audioUri: uri,
          audioDurationMs: recorderState.durationMillis,
        });
        setText('');
        await refresh();
      }
    } catch (e: any) {
      Alert.alert('Could not save recording', String(e?.message ?? e));
    }
  };

  const saveText = async () => {
    if (!text.trim()) {
      Alert.alert('Empty entry', 'Type something before saving, or record audio.');
      return;
    }
    const saved = await addEntry({ text: text.trim() });
    setText('');
    await refresh();
    // Fire-and-forget synthesis. Update the entry in place when it returns.
    void runSynthesis(saved.id, saved.text);
  };

  const runSynthesis = async (id: string, rawText: string) => {
    if (!rawText.trim()) return;
    // Mark pending so the UI shows a "synthesizing…" pill immediately.
    await updateEntry(id, { synthesisStatus: 'pending' });
    await refresh();
    const result = await synthesizeDream(rawText);
    if (result.status === 'ok') {
      await updateEntry(id, { synthesized: result.synthesized, synthesisStatus: 'ok' });
    } else {
      await updateEntry(id, { synthesisStatus: 'failed' });
    }
    await refresh();
  };

  const onDelete = (id: string) => {
    Alert.alert('Delete entry?', 'This cannot be undone.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: async () => {
          await deleteEntry(id);
          await refresh();
        },
      },
    ]);
  };

  const recording = recorderState.isRecording;
  const canRecord = recorderState.canRecord;

  return (
    <View style={[styles.container, { paddingTop: insets.top + spacing.md }]}>
      <Text style={styles.heading}>Dream Journal</Text>
      <Text style={styles.subheading}>
        {entries.length === 0
          ? 'No entries yet — type or record below.'
          : `${entries.length} entr${entries.length === 1 ? 'y' : 'ies'} on this device`}
      </Text>

      <View style={styles.inputCard}>
        <TextInput
          style={styles.input}
          value={text}
          onChangeText={setText}
          placeholder="What did you dream?"
          placeholderTextColor={colors.textDim}
          multiline
        />
        <View style={styles.buttonRow}>
          {!recording ? (
            <TouchableOpacity
              style={[styles.button, !canRecord && styles.buttonDisabled]}
              onPress={startRecording}
              disabled={!canRecord}
            >
              <Text style={styles.buttonText}>● Record</Text>
            </TouchableOpacity>
          ) : (
            <TouchableOpacity style={[styles.button, styles.buttonStop]} onPress={stopRecording}>
              <Text style={styles.buttonText}>■ Stop ({formatDuration(recorderState.durationMillis)})</Text>
            </TouchableOpacity>
          )}
          <TouchableOpacity
            style={[styles.button, styles.buttonSecondary, !text.trim() && styles.buttonDisabled]}
            onPress={saveText}
            disabled={!text.trim()}
          >
            <Text style={styles.buttonText}>Save Text</Text>
          </TouchableOpacity>
        </View>
        {recording ? (
          <View style={styles.recordingBar}>
            <View style={styles.recordingDot} />
            <Text style={styles.recordingText}>recording…</Text>
          </View>
        ) : null}
      </View>

      <FlatList
        data={entries}
        keyExtractor={item => item.id}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <Text style={styles.emptyHint}>Entries you save will appear here. They are stored locally on this device only.</Text>
        }
        renderItem={({ item }) => (
          <View style={styles.entryCard}>
            <View style={styles.entryHeader}>
              <Text style={styles.entryTimestamp}>{relativeTime(item.createdAt, now)}</Text>
              <TouchableOpacity onPress={() => onDelete(item.id)}>
                <Text style={styles.deleteText}>Delete</Text>
              </TouchableOpacity>
            </View>
            {item.text ? <Text style={styles.entryText}>{item.text}</Text> : null}
            {item.synthesized ? (
              <View style={styles.synthBlock}>
                <Text style={styles.synthLabel}>DIALECT</Text>
                <Text style={styles.synthText}>{item.synthesized}</Text>
              </View>
            ) : item.synthesisStatus === 'pending' ? (
              <Text style={styles.synthPending}>synthesizing…</Text>
            ) : item.synthesisStatus === 'failed' ? (
              <Text style={styles.synthFailed}>synthesis unavailable</Text>
            ) : null}
            {item.audioUri ? (
              <View style={styles.audioRow}>
                <AudioPlayer uri={item.audioUri} />
                {item.audioDurationMs ? (
                  <Text style={styles.audioMeta}>{formatDuration(item.audioDurationMs)}</Text>
                ) : null}
              </View>
            ) : null}
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg, padding: spacing.lg, gap: spacing.md },
  heading: { color: colors.text, fontSize: typography.title, fontWeight: '700' },
  subheading: { color: colors.textMuted, fontSize: typography.caption, marginTop: -spacing.sm },
  inputCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    gap: spacing.sm,
  },
  input: {
    color: colors.text,
    fontSize: typography.body,
    minHeight: 80,
    textAlignVertical: 'top',
  },
  buttonRow: { flexDirection: 'row', gap: spacing.sm },
  button: {
    backgroundColor: colors.red,
    borderRadius: radius.sm,
    paddingVertical: spacing.sm,
    paddingHorizontal: spacing.md,
    flex: 1,
    alignItems: 'center',
  },
  buttonSecondary: { backgroundColor: colors.accentDim },
  buttonStop: { backgroundColor: colors.red },
  buttonDisabled: { opacity: 0.4 },
  buttonText: { color: colors.white, fontSize: typography.caption, fontWeight: '700' },
  recordingBar: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  recordingDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: colors.red },
  recordingText: { color: colors.red, fontSize: typography.caption, fontWeight: '600' },
  list: { gap: spacing.md, paddingBottom: spacing.xxl },
  entryCard: {
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: spacing.md,
    gap: spacing.sm,
  },
  entryHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
  entryTimestamp: { color: colors.textMuted, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  deleteText: { color: colors.red, fontSize: typography.micro, fontWeight: '600' },
  entryText: { color: colors.text, fontSize: typography.body },
  audioRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  playButton: {
    backgroundColor: colors.blue,
    borderRadius: radius.sm,
    paddingVertical: 4,
    paddingHorizontal: spacing.md,
  },
  playText: { color: colors.white, fontSize: typography.micro, fontWeight: '700' },
  audioMeta: { color: colors.textMuted, fontSize: typography.micro, fontVariant: ['tabular-nums'] },
  emptyHint: { color: colors.textDim, fontSize: typography.caption, textAlign: 'center', padding: spacing.lg },
  synthBlock: {
    backgroundColor: colors.bg,
    borderRadius: radius.sm,
    padding: spacing.sm,
    borderLeftWidth: 2,
    borderLeftColor: colors.accent,
    gap: 4,
  },
  synthLabel: {
    color: colors.accent,
    fontSize: typography.micro,
    fontWeight: '700',
    letterSpacing: 1.2,
  },
  synthText: { color: colors.text, fontSize: typography.caption, lineHeight: 18 },
  synthPending: { color: colors.textDim, fontSize: typography.micro, fontStyle: 'italic' },
  synthFailed: { color: colors.textDim, fontSize: typography.micro },
});
