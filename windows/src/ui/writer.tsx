// The AI writer's status and its download / cancel / remove buttons (Profile and the Why sheet).

import { useCallback, useEffect, useState } from "react";
import { getWriter, gigabytes, type WriterStatus } from "../core/explainer";
import { Icon } from "./icons";

// Every screen showing the writer shares one status: a download started in the Why sheet
// shows up in Profile too.
const listeners = new Set<() => void>();
function refreshAll() {
  for (const fn of listeners) fn();
}

/** The writer's status; refreshed every second while downloading, otherwise on demand. */
export function useWriterStatus(): [WriterStatus | null, () => void] {
  const [status, setStatus] = useState<WriterStatus | null>(null);
  const [tick, setTick] = useState(0);
  const local = useCallback(() => setTick((t) => t + 1), []);
  useEffect(() => {
    listeners.add(local);
    return () => void listeners.delete(local);
  }, [local]);
  useEffect(() => {
    let live = true;
    void getWriter().status().then((s) => live && setStatus(s)).catch(() => {});
    return () => { live = false; };
  }, [tick]);
  useEffect(() => {
    if (status?.state !== "downloading") return;
    const t = setTimeout(refreshAll, 1000);
    return () => clearTimeout(t);
  }, [status]);
  return [status, refreshAll];
}

export function WriterControl({ status, refresh, compact }: { status: WriterStatus; refresh: () => void; compact?: boolean }) {
  const w = getWriter();
  const [busy, setBusy] = useState(false);
  const run = (f: () => Promise<void>) => async () => {
    setBusy(true);
    try { await f(); } finally { setBusy(false); refresh(); }
  };
  switch (status.state) {
    case "notDownloaded":
    case "error":
      return (
        <div className="writer-control">
          <button className="glass-button" disabled={busy} onClick={run(() => w.download())}>
            <Icon name="download" size={16} /> {status.state === "error" ? "Try again" : `Download AI writer (${gigabytes(status.sizeBytes)})`}
          </button>
          {!compact && <p className="footnote">{status.state === "error" ? status.detail : `${status.detail}. Downloaded once from Qualcomm; needs about twice that much free space while it unpacks.`}</p>}
          {compact && status.state === "error" && <p className="footnote">{status.detail}</p>}
        </div>
      );
    case "downloading": {
      const pct = status.sizeBytes ? Math.min(100, (status.received / status.sizeBytes) * 100) : 0;
      return (
        <div className="writer-control">
          <div className="progress"><div style={{ width: `${pct}%` }} /></div>
          <div className="writer-row">
            <span className="muted small">{pct >= 99.9 ? "Unpacking…" : `${gigabytes(status.received)} of ${gigabytes(status.sizeBytes)}`}</span>
            <button className="link-button small" onClick={run(() => w.cancel())}>Cancel</button>
          </div>
        </div>
      );
    }
    case "ready":
      return compact ? null : (
        <div className="writer-control">
          <p className="footnote">{status.detail}. Writes on this PC; the model only loads while it's writing.</p>
          <button className="text-button danger" disabled={busy} onClick={run(() => w.remove())}><Icon name="trash" size={16} /> Remove the AI writer ({gigabytes(status.sizeBytes)})</button>
        </div>
      );
    default:
      return compact ? null : <p className="footnote">{status.detail}</p>;
  }
}
