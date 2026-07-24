// useDiagnostics — polls /api/diagnostics every POLL.diagnostics ms.

import { useEffect, useState } from 'react';
import { apiClient } from '../api';
import type { StreamDiagnostics } from '../types/api';
import { POLL } from '../config';

export function useDiagnostics(): { data: StreamDiagnostics | null; error: string | null; lastUpdate: number } {
  const [data, setData] = useState<StreamDiagnostics | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdate, setLastUpdate] = useState<number>(0);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const d = await apiClient.getDiagnostics();
        if (!alive) return;
        setData(d);
        setError(null);
        setLastUpdate(Date.now());
      } catch (e: any) {
        if (!alive) return;
        setError(String(e?.message ?? e));
      }
    };
    tick();
    const id = setInterval(tick, POLL.diagnostics);
    return () => { alive = false; clearInterval(id); };
  }, []);

  return { data, error, lastUpdate };
}
