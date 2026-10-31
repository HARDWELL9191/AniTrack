// Entry point: connects the app to Windows (Tauri): HTTP without browser limits, mpv, the
// on-device AI, encrypted sign-ins, and the server's WebSocket.

import { createRoot } from "react-dom/client";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import { type EngineStatus, setEmbedder } from "./core/ai";
import { setFetch } from "./core/api";
import { type EngineEvent, type EngineInfo, setEngine } from "./core/engine";
import { AppModel, type TokenStore } from "./core/model";
import { PlayerController } from "./core/player";
import { startSocket, stopSocket } from "./core/socket";
import { setTmdbFetch } from "./core/tmdb";
import { App } from "./ui/app";
import { Provider, ui } from "./ui/state";
import "@fontsource-variable/inter";
import "./styles.css";

const native = isTauri();

// Windows (WebView2) and Linux (WebKitGTK) differ in a few details: the font (Segoe UI isn't on
// Linux, so Inter stands in), and WebKit can't bend the backdrop through an SVG lens.
{
  const forced = new URLSearchParams(location.search).get("platform");
  const ua = navigator.userAgent;
  const platform = forced ?? (/Windows/.test(ua) ? "windows" : /Linux|X11/.test(ua) ? "linux" : "other");
  document.documentElement.classList.add(`platform-${platform}`);
}

if (native) {
  setFetch((url, init) => tauriFetch(url, init) as never);
  setTmdbFetch((url, init) => tauriFetch(url, init) as never);

  const toVectors = (raw: Record<string, number[]>) => new Map(Object.entries(raw).map(([k, v]) => [Number(k), Float32Array.from(v)]));
  setEmbedder({
    status: () => invoke<EngineStatus>("ai_status"),
    cached: async (ids) => (ids.length ? toVectors(await invoke("ai_cached", { ids })) : new Map()),
    vectors: async (items) => (items.length ? toVectors(await invoke("ai_vectors", { items })) : new Map()),
  });

  const handlers = new Set<(e: EngineEvent) => void>();
  void listen<EngineEvent>("mpv", (e) => { for (const h of handlers) h(e.payload); });
  setEngine({
    info: () => invoke<EngineInfo>("mpv_info"),
    start: (options, observe) => invoke("mpv_start", { options, observe }),
    command: (args) => invoke("mpv_command", { args }),
    set: (name, value) => invoke("mpv_set", { name, value }),
    get: (name) => invoke<string | null>("mpv_get", { name }),
    setVisible: async () => { /* the video shows through the page while the player is open (video-mode) */ },
    destroy: () => invoke("mpv_destroy"),
    onEvent: (fn) => { handlers.add(fn); return () => void handlers.delete(fn); },
  });
}

// Browser preview only: a pretend engine so the player can be looked at (stripped from builds).
if (!native && import.meta.env.DEV && new URLSearchParams(location.search).has("mockplayer")) {
  const { mockEngine } = await import("./dev/mockEngine");
  setEngine(mockEngine());
}

const store: TokenStore = native
  ? { load: () => invoke<string | null>("accounts_load"), save: (data) => invoke("accounts_save", { data }) }
  : {
      // Browser preview only (development): kept in this browser.
      load: async () => localStorage.getItem("dev-accounts"),
      save: async (d) => (d ? localStorage.setItem("dev-accounts", d) : localStorage.removeItem("dev-accounts")),
    };

const deviceName = native ? await invoke<string>("device_name").catch(() => "Windows") : "Browser";
const model = new AppModel(store, `JellyReco on ${deviceName}`);
const player = new PlayerController(() => model.api, () => model.settings);
model.player = player;
player.onError = (msg) => model.toast(msg, "error");
player.onDataChanged = () => model.dataChanged();
(window as unknown as { jellyreco: AppModel }).jellyreco = model;

// The server's WebSocket follows the signed-in account.
let socketFor = "";
model.subscribe(() => {
  const key = model.api && model.user ? `${model.api.server}|${model.user.Id}|${model.api.token}` : "";
  if (key === socketFor) return;
  socketFor = key;
  if (!key) { stopSocket(); return; }
  startSocket(model.api!, {
    player: () => model.player,
    dataChanged: () => model.dataChanged(),
    toast: (t) => model.toast(t),
    message: (header, text) => model.toast(`${header}: ${text}`),
    goHome: () => { ui.popToRoot(model.tab); model.tab = "home"; model.notify(); },
  });
});

// Battery saver on: the AI part pauses (checked every half minute).
if (native) {
  const check = () => void invoke<boolean>("power_saver").then((on) => { model.powerSaver = on; }).catch(() => {});
  check();
  setInterval(check, 30_000);
  // A video file opened with the app (or dropped on the exe): play it with mpv directly.
  void listen<string>("open-file", (e) => void playLocalFile(e.payload));
}

async function playLocalFile(path: string) {
  try {
    await player.playNow([{ Id: `local:${path}`, Name: path.split(/[\\/]/).pop() ?? path, Type: "Video", MediaType: "Video", Path: path }], 0);
  } catch (e) {
    model.fail(e);
  }
}

// Liquid Glass: the light on a glass control follows the pointer (CSS reads --mx/--my).
const GLASS = ".glass-button, .round-button, .dropdown-button, .segmented button, .tabbar button";
let lit: HTMLElement | null = null;
window.addEventListener("pointermove", (e) => {
  const el = (e.target as HTMLElement | null)?.closest?.(GLASS) as HTMLElement | null;
  if (lit && lit !== el) { lit.style.removeProperty("--mx"); lit.style.removeProperty("--my"); }
  lit = el;
  if (!el) return;
  const r = el.getBoundingClientRect();
  el.style.setProperty("--mx", `${e.clientX - r.left}px`);
  el.style.setProperty("--my", `${e.clientY - r.top}px`);
}, { passive: true });

// No browser right-click menu (the app has its own) and no Ctrl+wheel page zoom.
window.addEventListener("contextmenu", (e) => {
  const t = e.target as HTMLElement;
  if (!t.closest("input, textarea, pre, .log")) e.preventDefault();
});
window.addEventListener("wheel", (e) => { if (e.ctrlKey) e.preventDefault(); }, { passive: false });
window.addEventListener("beforeunload", () => { void player.shutdown(); });

createRoot(document.getElementById("root")!).render(
  <Provider model={model}>
    <App />
  </Provider>,
);

void model.bootstrap();
