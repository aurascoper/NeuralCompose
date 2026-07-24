// useClassifier — polls /api/classifier every POLL.classifier ms.

import { useEffect, useState } from 'react';
import { apiClient } from '../api';
import type { IntentPrediction } from '../types/api';
import { POLL } from '../config';

export function useClassifier(): { data: IntentPrediction | null; error: string | null; lastUpdate: number } {
  const [data, setData] = useState<IntentPrediction | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdate, setLastUpdate] = useState<number>(0);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const d = await apiClient.getClassifier();
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
    const id = setInterval(tick, POLL.classifier);
    return () => { alive = false; clearInterval(id); };
  }, []);

  return { data, error, lastUpdate };
}
