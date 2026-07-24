// usePipelineMode — polls /api/pipeline-mode every POLL.pipelineMode ms.

import { useEffect, useState } from 'react';
import { apiClient } from '../api';
import type { PipelineMode } from '../types/api';
import { POLL } from '../config';

export function usePipelineMode(): { data: PipelineMode | null; error: string | null } {
  const [data, setData] = useState<PipelineMode | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const d = await apiClient.getPipelineMode();
        if (!alive) return;
        setData(d);
        setError(null);
      } catch (e: any) {
        if (!alive) return;
        setError(String(e?.message ?? e));
      }
    };
    tick();
    const id = setInterval(tick, POLL.pipelineMode);
    return () => { alive = false; clearInterval(id); };
  }, []);

  return { data, error };
}
