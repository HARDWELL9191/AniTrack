// Welcome / login (port of WelcomeView in RootView.swift). AniList's implicit login opens in your
// browser and comes back through the anireco:// link (the redirect URL set in your AniList client).

import { useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import logo from "../assets/logo.png";
import { Icon } from "./icons";
import { useModel } from "./state";

export const REDIRECT_URL = "anireco://auth";

export function authorizeURL(clientId: string): string | null {
  const id = clientId.trim();
  return /^\d+$/.test(id) ? `https://anilist.co/api/v2/oauth/authorize?client_id=${id}&response_type=token` : null;
}

export function WelcomePage() {
  const model = useModel();
  const [clientId, setClientId] = useState(model.settings.clientId);
  const [username, setUsername] = useState("");
  const [showUsername, setShowUsername] = useState(false);
  const [working, setWorking] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const url = authorizeURL(clientId);

  const logIn = async () => {
    model.settings.clientId = clientId.trim();
    if (!url) return;
    setWaiting(true);
    try {
      await openUrl(url);
    } catch (e) {
      setWaiting(false);
      model.showError((e as Error).message ?? String(e));
    }
  };

  return (
    <div className="welcome">
      <div className="welcome-card panel">
        <img className="welcome-logo" src={logo} alt="" />
        <h1>AniReco</h1>
        <p className="muted">Track, discover and get personal picks from your AniList.</p>

        <label className="field">
          <span>AniList Client ID</span>
          <input value={clientId} inputMode="numeric" onChange={(e) => setClientId(e.target.value.replace(/\D/g, ""))} placeholder="e.g. 12345" />
        </label>
        <p className="footnote">Create one once at anilist.co/settings/developer with the redirect URL <strong>{REDIRECT_URL}</strong>.</p>

        <button className="glass-button prominent big wide" disabled={!url || working} onClick={logIn}>
          <Icon name="key" size={18} /> Log in with AniList
        </button>
        {waiting && <p className="footnote center-text">Finish logging in in your browser; AniReco opens again by itself.</p>}
        <button className="glass-button big wide" onClick={() => setShowUsername(!showUsername)}>
          <Icon name="eye" size={18} /> Just browse with my username
        </button>
        {showUsername && (
          <div className="username">
            <label className="field">
              <span>AniList username</span>
              <input value={username} onChange={(e) => setUsername(e.target.value)} spellCheck={false}
                onKeyDown={(e) => { if (e.key === "Enter" && username.trim()) void go(); }} />
            </label>
            <button className="glass-button wide" disabled={working || !username.trim()} onClick={() => void go()}>Continue read-only</button>
            <p className="footnote">Your profile must be public. You can't edit your list in this mode.</p>
          </div>
        )}
        {working && <span className="spinner" />}
      </div>
    </div>
  );

  async function go() {
    setWorking(true);
    await model.useUsername(username);
    setWorking(false);
  }
}
