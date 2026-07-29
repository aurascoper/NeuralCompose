// TranscriptionClient.ts — local speech-to-text seam.
// Real provider: whisper.cpp server on 127.0.0.1:8083.
// API: POST /inference with multipart form data (file, temperature, response_format).
// When no STT is available, falls back to manual text injection (clearly labeled).

export const STT_URL = process.env.EXPO_PUBLIC_STT_URL || 'http://127.0.0.1:8083';

export interface TranscriptionResult {
  text: string;
  backend: string;
  model: string;
  latencyMs: number;
}

export interface TranscriptionError {
  reason: string;
  latencyMs: number;
}

export interface TranscriptionClientOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

/**
 * Transcribes an audio file by POSTing it to the local whisper.cpp /inference endpoint.
 * The server accepts multipart form data with a "file" field containing the audio.
 */
export async function transcribeAudio(
  audioUri: string,
  opts: TranscriptionClientOptions = {},
): Promise<TranscriptionResult | TranscriptionError> {
  const timeoutMs = opts.timeoutMs ?? 30000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  if (opts.signal) {
    if (opts.signal.aborted) {
      clearTimeout(timer);
      return { reason: 'cancelled', latencyMs: 0 };
    }
    opts.signal.addEventListener('abort', () => controller.abort(), { once: true });
  }

  const start = Date.now();

  try {
    // whisper.cpp /inference expects multipart form data with "file" field
    const formData = new FormData();
    formData.append('file', {
      uri: audioUri,
      type: 'audio/wav',
      name: 'recording.wav',
    } as any);
    formData.append('temperature', '0.0');
    formData.append('temperature_inc', '0.2');
    formData.append('response_format', 'json');

    const res = await fetch(`${STT_URL}/inference`, {
      method: 'POST',
      body: formData,
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      return { reason: `HTTP ${res.status}`, latencyMs: Date.now() - start };
    }
    const json = (await res.json()) as {
      text?: string;
      model?: string;
    };

    if (!json.text?.trim()) {
      return { reason: 'empty transcript', latencyMs: Date.now() - start };
    }

    return {
      text: json.text.trim(),
      backend: 'whisper.cpp',
      model: json.model ?? 'ggml-tiny.en-q5_1',
      latencyMs: Date.now() - start,
    };
  } catch (err: any) {
    clearTimeout(timer);
    if (err?.name === 'AbortError') {
      return { reason: 'timeout', latencyMs: Date.now() - start };
    }
    return { reason: String(err?.message ?? err), latencyMs: Date.now() - start };
  }
}

/** Quick health check for the STT service. */
export async function sttAlive(): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 2000);
    const res = await fetch(`${STT_URL}/health`, { signal: ctrl.signal });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}