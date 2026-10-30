// Development only (never in the installed app): a pretend mpv for the browser preview, so the
// player's screens can be looked at without Windows. Loaded with ?mockplayer in `npm run dev`.

import type { Engine, EngineEvent } from "../core/engine";

export function mockEngine(): Engine {
  const handlers = new Set<(e: EngineEvent) => void>();
  const props = new Map<string, string>([["volume", "80"], ["mute", "no"], ["speed", "1"], ["pause", "no"], ["sub-delay", "0"], ["sub-scale", "1"], ["sub-pos", "100"]]);
  const emit = (e: EngineEvent) => setTimeout(() => { for (const h of handlers) h(e); }, 0);
  const prop = (name: string, value: string | null) => { if (value !== null) props.set(name, value); emit({ type: "property", name, value }); };
  const tracks = JSON.stringify([
    { id: 1, type: "video", "ff-index": 0, codec: "hevc", selected: true, "demux-w": 1920, "demux-h": 1080 },
    { id: 1, type: "audio", "ff-index": 1, codec: "flac", lang: "jpn", selected: true, "demux-channel-count": 2 },
    { id: 2, type: "audio", "ff-index": 2, codec: "eac3", lang: "eng", "demux-channel-count": 6 },
    { id: 1, type: "sub", "ff-index": 3, codec: "ass", lang: "eng", title: "Full", selected: true },
    { id: 2, type: "sub", "ff-index": 4, codec: "ass", lang: "eng", title: "Signs & Songs", forced: true },
    { id: 3, type: "sub", "ff-index": 5, codec: "subrip", lang: "slv" },
  ]);
  return {
    info: async () => ({ available: true, detail: "Preview engine", version: "mock" }),
    start: async () => {},
    command: async (args) => {
      if (args[0] === "loadfile") {
        emit({ type: "start-file" });
        prop("duration", "1440");
        prop("track-list", tracks);
        prop("aid", "1");
        prop("sid", "1");
        emit({ type: "file-loaded" });
        prop("time-pos", "540");
        prop("demuxer-cache-time", "720");
        prop("pause", "no");
        prop("volume", props.get("volume")!);
        emit({ type: "playback-restart" });
      } else if (args[0] === "seek") prop("time-pos", String(Math.max(0, Number(props.get("time-pos") ?? 0) + Number(args[1] ?? 0))));
      else if (args[0] === "cycle" && args[1] === "pause") prop("pause", props.get("pause") === "yes" ? "no" : "yes");
    },
    set: async (name, value) => prop(name, value),
    get: async (name) => props.get(name) ?? null,
    setVisible: async () => {},
    destroy: async () => {},
    onEvent: (fn) => { handlers.add(fn); return () => void handlers.delete(fn); },
  };
}
