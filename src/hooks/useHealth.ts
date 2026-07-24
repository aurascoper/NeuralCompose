// useHealth — polls /api/health every POLL.health ms.

import { useEffect, useState } from 'react';
import { apiClient } from '../api';
import type { ChannelHealthState } from '../types/api';
import { POLL } from '../config';

export function useHealth(): { data: ChannelHealthState[]; error: string | null; lastUpdate: number } {
  const [data, setData] = useState<ChannelHealthState[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [lastUpdate, setLastUpdate] = useState<number>(0);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const d = await apiClient.getHealth();
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
    const id = setInterval(tick, POLL.health);
    return () => { alive = false; clearInterval(id); };
  }, []);

  return { data, error, lastUpdate };
}
