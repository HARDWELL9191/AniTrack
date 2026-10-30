// The playback engine as the UI sees it: mpv in the native side, driven by commands and
// properties, reporting back through events. The browser preview has no engine.

export type EngineEvent =
  | { type: "property"; name: string; value: string | null }
  | { type: "start-file" }
  | { type: "file-loaded" }
  | { type: "end-file"; reason: "eof" | "stop" | "quit" | "error" | "redirect" | "unknown"; error?: string }
  | { type: "playback-restart" }
  | { type: "seek" }
  | { type: "video-reconfig" }
  | { type: "idle" }
  | { type: "log"; level: string; prefix: string; text: string }
  | { type: "shutdown" };

export interface EngineInfo {
  available: boolean;
  detail: string;
  version?: string;
}

export interface Engine {
  info(): Promise<EngineInfo>;
  /** Creates mpv (once) with these options and shows the video surface under the UI. */
  start(options: Record<string, string>, observe: string[]): Promise<void>;
  command(args: string[]): Promise<void>;
  set(name: string, value: string): Promise<void>;
  get(name: string): Promise<string | null>;
  /** Shows or hides the video surface (the UI becomes see-through while it's shown). */
  setVisible(visible: boolean): Promise<void>;
  /** Stops playback and destroys mpv (frees the GPU and decoders). */
  destroy(): Promise<void>;
  onEvent(fn: (e: EngineEvent) => void): () => void;
}

class NoEngine implements Engine {
  async info(): Promise<EngineInfo> {
    return { available: false, detail: "Playback runs in the installed Windows app (this is the browser preview)." };
  }
  async start() { throw new Error("Playback is only available in the installed app."); }
  async command() {}
  async set() {}
  async get() { return null; }
  async setVisible() {}
  async destroy() {}
  onEvent() { return () => {}; }
}

let engine: Engine = new NoEngine();
export const setEngine = (e: Engine) => (engine = e);
export const getEngine = () => engine;
