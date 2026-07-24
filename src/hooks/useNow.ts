// Utility: format a unix-ms timestamp as a relative "Ns ago" string, refreshing each second.
import { useEffect, useState } from 'react';

export function relativeTime(unixSeconds: number | string, nowMs: number = Date.now()): string {
  const t = typeof unixSeconds === 'string' ? Date.parse(unixSeconds) : unixSeconds * 1000;
  const delta = Math.max(0, Math.floor((nowMs - t) / 1000));
  if (delta < 1) return 'just now';
  if (delta < 60) return `${delta}s ago`;
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  return `${Math.floor(delta / 86400)}d ago`;
}

export function useNow(intervalMs: number = 1000): number {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), intervalMs);
    return () => clearInterval(id);
  }, [intervalMs]);
  return now;
}
