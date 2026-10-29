// Profile / settings (port of SettingsView.swift).

import { useEffect, useState } from "react";
import { type EngineStatus, getEmbedder } from "../core/ai";
import { TITLE_LANGUAGES, type TitleLanguage } from "../core/models";
import { REDIRECT_URL } from "./welcome";
import { PageHeader } from "./components";
import { ProfileHeader } from "./home";
import { Icon } from "./icons";
import { ui, useModel } from "./state";

function Toggle({ label, checked, onChange, detail }: { label: string; checked: boolean; onChange: (v: boolean) => void; detail?: string }) {
  return (
    <label className="toggle-row">
      <span>{label}{detail && <small className="muted"> {detail}</small>}</span>
      <input type="checkbox" className="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

const backendText: Record<EngineStatus["backend"], string> = {
  npu: "Snapdragon NPU",
  "npu+cpu": "Snapdragon NPU + CPU",
  cpu: "CPU",
  off: "Off",
};

export function ProfilePage() {
  const model = useModel();
  const s = model.settings;
  const [token, setToken] = useState("");
  const [confirmLogout, setConfirmLogout] = useState(false);
  const [engine, setEngine] = useState<EngineStatus | null>(null);
  useEffect(() => {
    let live = true;
    const poll = () => void getEmbedder().status().then((st) => live && setEngine(st));
    poll();
    const t = setInterval(poll, 4000);
    return () => { live = false; clearInterval(t); };
  }, []);

  return (
    <div className="page narrow">
      <PageHeader title="Profile" />
      <section className="group panel">
        <div className="group-title">Account</div>
        <ProfileHeader />
        <div className="row-line">
          {model.mode.kind === "loggedIn" ? <span><Icon name="checkCircle" size={16} /> Logged in with AniList</span>
            : model.mode.kind === "username" ? <span><Icon name="eye" size={16} /> Read-only as {model.mode.name}</span> : null}
        </div>
        {confirmLogout ? (
          <div className="confirm">
            <span>Log out of AniTrack?</span>
            <button className="glass-button danger" onClick={() => void model.logOut()}>Log out</button>
            <button className="glass-button" onClick={() => setConfirmLogout(false)}>Cancel</button>
          </div>
        ) : (
          <button className="text-button danger" onClick={() => setConfirmLogout(true)}><Icon name="logout" size={16} /> Log out</button>
        )}
      </section>

      <section className="group panel">
        <div className="group-title">Display</div>
        <label className="toggle-row">
          <span>Titles</span>
          <select value={s.titleLanguage} onChange={(e) => (s.titleLanguage = e.target.value as TitleLanguage)}>
            {TITLE_LANGUAGES.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
          </select>
        </label>
        <Toggle label="Hide Chinese animation" checked={s.hideChinese} onChange={(v) => { s.hideChinese = v; model.invalidatePicks(); }} />
      </section>

      <section className="group panel">
        <div className="group-title">Your lists</div>
        <button className="text-button" disabled={!model.entries.length && !s.dismissedPicks.size} onClick={() => ui.openSheet({ kind: "export" })}>
          <Icon name="table" size={16} /> Export lists to Excel
        </button>
        <p className="footnote">Choose which lists to include; each one becomes a sheet in a single .xlsx file.</p>
      </section>

      <section className="group panel">
        <div className="group-title">For You picks</div>
        <Toggle label="On-device AI ranking" checked={s.useOnDeviceAI} onChange={(v) => { s.useOnDeviceAI = v; model.invalidatePicks(); model.aiAvailabilityChanged(); }} />
        <div className="toggle-row">
          <span><Icon name="chip" size={16} /> AI runs on</span>
          <span className="muted" title={engine?.detail}>{engine ? backendText[engine.backend] : "…"}</span>
        </div>
        {engine && <p className="footnote">{engine.detail}</p>}
        <Toggle label="Include unreleased shows" checked={s.includeUnreleased} onChange={(v) => { s.includeUnreleased = v; model.invalidatePicks(); }} />
        <button className="text-button" disabled={model.isLoadingFeed(null)} onClick={() => void model.generateRecommendations(null, true)}>Rebuild picks now</button>
        <button className="text-button" disabled={!s.dismissedPicks.size || model.isResettingNotForMe} onClick={() => model.resetDismissedPicks()}>
          Reset "Not for me" ({s.dismissedPicks.size})
        </button>
        <p className="footnote">
          Picks combine fan recommendations from the shows you rated highly, your favorite genres and tags, and (when on-device AI is on) the meaning
          of each synopsis, compared on this PC by a small language model on the Snapdragon NPU (or the CPU). Nothing leaves your PC except normal
          AniList requests. "Not for me" is saved to your AniList as a private, hidden custom list, so it follows you to your iPhone. Each synopsis is
          analyzed once and saved, and the AI pauses while battery saver is on.
        </p>
      </section>

      <section className="group panel">
        <div className="group-title">AniList API</div>
        <label className="field">
          <span>AniList client ID</span>
          <input value={s.clientId} inputMode="numeric" onChange={(e) => (s.clientId = e.target.value.replace(/\D/g, ""))} placeholder="e.g. 12345" />
        </label>
        <label className="field">
          <span>Paste an access token (optional)</span>
          <input type="password" value={token} onChange={(e) => setToken(e.target.value)} />
        </label>
        <button className="text-button" disabled={!token.trim()} onClick={() => { void model.useToken(token); setToken(""); }}><Icon name="key" size={16} /> Use token</button>
        <p className="footnote">Redirect URL for your AniList client: {REDIRECT_URL}. The token is encrypted for your Windows account and lasts one year.</p>
      </section>

      <section className="group panel">
        <div className="group-title">About</div>
        <div className="toggle-row"><span>Version</span><span className="muted">1.0.0 (Windows on ARM)</span></div>
        <p className="footnote">AniTrack is an unofficial client and isn't affiliated with AniList.co.</p>
      </section>
    </div>
  );
}
