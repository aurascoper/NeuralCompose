// DreamJournal — AsyncStorage CRUD for dream reports.
// Local-only. No M4 sync in v0.1 (per the prompt, Part 5.5 + Part 10).
//
// Uses @react-native-async-storage/async-storage. The SDK 57 bundled version is 2.2.0
// (npm latest 3.1.1 also works). We import the runtime, not a specific version.

import AsyncStorage from '@react-native-async-storage/async-storage';

export type SynthesisStatus = 'pending' | 'ok' | 'failed';

export interface DreamEntry {
  id: string;
  createdAt: number;      // unix ms
  text: string;           // user-typed report (may be empty if voice-only)
  audioUri?: string;      // local file URI from expo-audio
  audioDurationMs?: number;
  synthesized?: string;   // dialect rewrite produced by local Qwen; undefined if not run
  synthesisStatus?: SynthesisStatus; // 'pending' while in-flight, 'ok' on success, 'failed' on error
}

const STORAGE_KEY = 'neuralcompose.dreamjournal.v1';

function uuid(): string {
  // RFC 4122 v4-ish without crypto dep. Not cryptographically strong; fine for local IDs.
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export async function listEntries(): Promise<DreamEntry[]> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as DreamEntry[];
    return parsed.sort((a, b) => b.createdAt - a.createdAt);
  } catch {
    return [];
  }
}

export async function addEntry(input: { text: string; audioUri?: string; audioDurationMs?: number }): Promise<DreamEntry> {
  const entry: DreamEntry = {
    id: uuid(),
    createdAt: Date.now(),
    text: input.text,
    audioUri: input.audioUri,
    audioDurationMs: input.audioDurationMs,
  };
  const existing = await listEntries();
  const next = [entry, ...existing];
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  return entry;
}

export async function deleteEntry(id: string): Promise<void> {
  const existing = await listEntries();
  const next = existing.filter(e => e.id !== id);
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
}

export async function updateEntry(id: string, patch: Partial<DreamEntry>): Promise<DreamEntry | null> {
  const existing = await listEntries();
  const idx = existing.findIndex(e => e.id === id);
  if (idx === -1) return null;
  const merged: DreamEntry = { ...existing[idx], ...patch, id: existing[idx].id, createdAt: existing[idx].createdAt };
  const next = [...existing];
  next[idx] = merged;
  await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  return merged;
}

export async function clearAll(): Promise<void> {
  await AsyncStorage.removeItem(STORAGE_KEY);
}
