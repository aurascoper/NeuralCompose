// dialecticSessionStore.ts — opt-in local persistence for live dialectic sessions.
// Default is ephemeral. Only persists when the user explicitly opts in.
// Never persists raw microphone audio by default.
// Never merges live-session records into Dream Journal entries.

import AsyncStorage from '@react-native-async-storage/async-storage';
import type { ProfileID } from '../dialectic/types';

export interface DialecticSessionSummary {
  id: string;
  startedAt: number;
  endedAt: number;
  profile: ProfileID;
  turnCount: number;
  outcomes: Record<string, number>;
  tensionAvg?: number;
  timingSummary?: Record<string, { p50: number; p95: number; max: number; count: number }>;
  modelProvenance?: string;
  embedderProvenance?: string;
  sttBackend?: string;
  ttsBackend?: string;
  // Only included if user opts in to text persistence
  turns?: Array<{
    heard?: string;
    spoken?: string;
    outcome: string;
    tension: number;
    timestamp: number;
  }>;
}

const STORAGE_KEY = 'neuralcompose.dialectic-sessions.v1';

function uuid(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export async function saveSessionSummary(
  summary: Omit<DialecticSessionSummary, 'id'>,
): Promise<DialecticSessionSummary> {
  const full: DialecticSessionSummary = { ...summary, id: uuid() };
  try {
    const existing = await listSessions();
    const next = [full, ...existing].slice(0, 50); // keep last 50
    await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Storage is best-effort; don't block the session
  }
  return full;
}

export async function listSessions(): Promise<DialecticSessionSummary[]> {
  try {
    const raw = await AsyncStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    return JSON.parse(raw) as DialecticSessionSummary[];
  } catch {
    return [];
  }
}

export async function clearSessions(): Promise<void> {
  await AsyncStorage.removeItem(STORAGE_KEY);
}