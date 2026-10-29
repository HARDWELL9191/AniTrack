// Entry point: connects the shared app logic to Windows (Tauri): HTTP without browser limits,
// the on-device AI in the native side, the encrypted token, and the anitrack:// login link.

import { createRoot } from "react-dom/client";
import { invoke, isTauri } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { fetch as tauriFetch } from "@tauri-apps/plugin-http";
import { getCurrent, onOpenUrl } from "@tauri-apps/plugin-deep-link";
import { setFetch } from "./core/anilist";
import { type EngineStatus, setEmbedder } from "./core/ai";
import { AppModel, type TokenStore } from "./core/model";
import { App } from "./ui/app";
import { Provider } from "./ui/state";
import "./styles.css";

const native = isTauri();

if (native) {
  setFetch((url, init) => tauriFetch(url, init) as never);
  const toVectors = (raw: Record<string, number[]>) => new Map(Object.entries(raw).map(([k, v]) => [Number(k), Float32Array.from(v)]));
  setEmbedder({
    status: () => invoke<EngineStatus>("ai_status"),
    cached: async (ids) => (ids.length ? toVectors(await invoke("ai_cached", { ids })) : new Map()),
    vectors: async (items) => (items.length ? toVectors(await invoke("ai_vectors", { items })) : new Map()),
  });
}

const tokens: TokenStore = native
  ? { get: () => invoke<string | null>("token_get"), set: (token) => invoke("token_set", { token }) }
  : {
      // Browser preview only (development): kept in this browser.
      get: async () => localStorage.getItem("dev-token"),
      set: async (t) => (t ? localStorage.setItem("dev-token", t) : localStorage.removeItem("dev-token")),
    };

// Battery saver on: the AI part pauses (checked every half minute, it's a cheap call).
let saver = false;
if (native) {
  const check = () => void invoke<boolean>("power_saver").then((on) => {
    const changed = on !== saver;
    saver = on;
    if (changed && !on) model.aiAvailabilityChanged();
  }).catch(() => {});
  check();
  setInterval(check, 30_000);
}

const model = new AppModel(tokens, () => !saver);
(window as unknown as { anitrack: AppModel }).anitrack = model;

// The login link: on first launch it's in the launch arguments, later a second launch hands it over.
let lastLink = "";
const handleLink = (url: string) => {
  if (!url.startsWith("anitrack://") || url === lastLink) return;
  lastLink = url;
  void model.handleAuthCallback(url);
};
if (native) {
  void getCurrent().then((urls) => urls?.forEach(handleLink)).catch(() => {});
  void onOpenUrl((urls) => urls.forEach(handleLink)).catch(() => {});
  void listen<string>("auth-link", (e) => handleLink(e.payload));
}

createRoot(document.getElementById("root")!).render(
  <Provider model={model}>
    <App />
  </Provider>,
);

void model.bootstrap();
