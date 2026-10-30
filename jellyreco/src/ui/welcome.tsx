// Sign in: add a server (address), pick a user or type a name, password or Quick Connect.
// Saved servers and accounts are listed first, so switching is one click.

import { useEffect, useRef, useState } from "react";
import type { Jellyfin } from "../core/api";
import type { SavedServer } from "../core/model";
import type { User } from "../core/types";
import appIcon from "../assets/app-icon.png";
import { Cover, Field, Spinner } from "./components";
import { Icon } from "./icons";
import { useModel } from "./state";

type Step =
  | { kind: "servers" }
  | { kind: "address" }
  | { kind: "users"; api: Jellyfin; server: { id: string; name: string; version?: string }; users: User[]; quick: boolean }
  | { kind: "password"; api: Jellyfin; server: { id: string; name: string; version?: string }; user?: User; quick: boolean }
  | { kind: "quick"; api: Jellyfin; server: { id: string; name: string; version?: string }; code: string; secret: string };

export function WelcomePage() {
  const model = useModel();
  const [step, setStep] = useState<Step>(model.servers.length ? { kind: "servers" } : { kind: "address" });
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const openServer = async (address: string) => {
    setBusy(true);
    setError(null);
    try {
      const { api, name, id, version, startupDone } = await model.connect(address);
      if (!startupDone) throw new Error("This server hasn't been set up yet. Finish its setup wizard in a browser first.");
      const server = { id, name, version };
      const [users, quick] = await Promise.all([api.publicUsers().catch(() => [] as User[]), api.quickConnectEnabled().catch(() => false)]);
      setStep(users.length ? { kind: "users", api, server, users, quick } : { kind: "password", api, server, quick });
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="welcome">
      <div className="welcome-card panel">
        <img className="welcome-logo" src={appIcon} alt="" />
        <h1>JellyReco</h1>
        {step.kind === "servers" && <Servers onAdd={() => setStep({ kind: "address" })} onOpen={(s) => openServer(s.url)} busy={busy} />}
        {step.kind === "address" && <Address onConnect={openServer} busy={busy} back={model.servers.length ? () => setStep({ kind: "servers" }) : undefined} />}
        {step.kind === "users" && (
          <Users step={step} onPick={(u) => setStep({ kind: "password", api: step.api, server: step.server, user: u, quick: step.quick })}
            onOther={() => setStep({ kind: "password", api: step.api, server: step.server, quick: step.quick })}
            back={() => setStep(model.servers.length ? { kind: "servers" } : { kind: "address" })} />
        )}
        {step.kind === "password" && (
          <Password step={step} setError={setError}
            onQuick={async () => {
              setError(null);
              try {
                const r = await step.api.quickConnectInitiate();
                setStep({ kind: "quick", api: step.api, server: step.server, code: r.Code, secret: r.Secret });
              } catch (e) { setError((e as Error).message); }
            }}
            back={() => void openServer(step.api.server)} />
        )}
        {step.kind === "quick" && <Quick step={step} setError={setError} back={() => void openServer(step.api.server)} />}
        {error && <p className="footnote error">{error}</p>}
      </div>
    </div>
  );
}

function Servers({ onAdd, onOpen, busy }: { onAdd: () => void; onOpen: (s: SavedServer) => void; busy: boolean }) {
  const model = useModel();
  return (
    <div className="username">
      <p className="muted">Choose a server</p>
      <div className="rows">
        {model.servers.map((s) => (
          <div key={s.id} className="server-row">
            <button className="row" onClick={() => onOpen(s)} disabled={busy}>
              <Icon name="server" size={22} />
              <div className="row-text">
                <div className="row-title">{s.name}</div>
                <div className="row-sub">{s.url}{s.version ? ` · ${s.version}` : ""}</div>
              </div>
              <Icon name="chevronRight" size={16} className="row-chevron" />
            </button>
            {s.accounts.map((a) => (
              <button key={a.userId} className="chip chip-button" onClick={() => void model.switchAccount(s, a.userId)}>Continue as {a.name}</button>
            ))}
            <button className="text-button danger small" onClick={() => void model.forgetServer(s.id)}>Forget</button>
          </div>
        ))}
      </div>
      <button className="glass-button" onClick={onAdd}><Icon name="plus" size={16} /> Add a server</button>
    </div>
  );
}

function Address({ onConnect, busy, back }: { onConnect: (a: string) => void; busy: boolean; back?: () => void }) {
  const [address, setAddress] = useState("");
  return (
    <form className="username" onSubmit={(e) => { e.preventDefault(); if (address.trim()) onConnect(address); }}>
      <p className="muted">Connect to your Jellyfin server.</p>
      <Field label="Server address" hint="For example 192.168.1.20:8096 or https://jellyfin.example.com">
        <input autoFocus value={address} onChange={(e) => setAddress(e.target.value)} placeholder="http://192.168.1.20:8096" spellCheck={false} />
      </Field>
      <button className="glass-button prominent big wide" disabled={busy || !address.trim()}>{busy ? <span className="spinner small" /> : "Connect"}</button>
      {back && <button type="button" className="text-button" onClick={back}><Icon name="chevronLeft" size={15} /> Saved servers</button>}
    </form>
  );
}

function Users({ step, onPick, onOther, back }: { step: Extract<Step, { kind: "users" }>; onPick: (u: User) => void; onOther: () => void; back: () => void }) {
  return (
    <div className="username">
      <p className="muted">Who's watching on {step.server.name}?</p>
      <div className="user-grid">
        {step.users.map((u) => (
          <button key={u.Id} className="user-tile" onClick={() => onPick(u)}>
            <Cover url={u.PrimaryImageTag ? step.api.userImage(u.Id, u.PrimaryImageTag, 160) : undefined} width={84} height={84} radius={42} icon="user" />
            <span>{u.Name}</span>
          </button>
        ))}
      </div>
      <button className="glass-button" onClick={onOther}>Someone else</button>
      <button className="text-button" onClick={back}><Icon name="chevronLeft" size={15} /> Back</button>
    </div>
  );
}

function Password({ step, setError, onQuick, back }: { step: Extract<Step, { kind: "password" }>; setError: (e: string | null) => void; onQuick: () => void; back: () => void }) {
  const model = useModel();
  const [name, setName] = useState(step.user?.Name ?? "");
  const [pw, setPw] = useState("");
  const [busy, setBusy] = useState(false);
  const submit = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await step.api.authenticate(name, pw);
      if (!r.AccessToken || !r.User) throw new Error("The server didn't sign you in.");
      await model.signedInWith(step.api, step.server, r.AccessToken, r.User);
    } catch (e) {
      const msg = (e as Error).message;
      setError(msg.includes("401") || msg.includes("expired") ? "Wrong name or password." : msg);
    } finally {
      setBusy(false);
    }
  };
  return (
    <form className="username" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
      <p className="muted">Sign in to {step.server.name}</p>
      {!step.user && <Field label="Name"><input autoFocus value={name} onChange={(e) => setName(e.target.value)} spellCheck={false} /></Field>}
      {step.user && <div className="signin-user"><Cover url={step.user.PrimaryImageTag ? step.api.userImage(step.user.Id, step.user.PrimaryImageTag, 120) : undefined} width={48} height={48} radius={24} icon="user" /><strong>{step.user.Name}</strong></div>}
      {(!step.user || step.user.HasPassword) && <Field label="Password"><input type="password" autoFocus={!!step.user} value={pw} onChange={(e) => setPw(e.target.value)} /></Field>}
      <button className="glass-button prominent big wide" disabled={busy || !name.trim()}>{busy ? <span className="spinner small" /> : "Sign in"}</button>
      {step.quick && <button type="button" className="glass-button wide" onClick={onQuick}><Icon name="zap" size={16} /> Use Quick Connect</button>}
      <button type="button" className="text-button" onClick={back}><Icon name="chevronLeft" size={15} /> Back</button>
    </form>
  );
}

function Quick({ step, setError, back }: { step: Extract<Step, { kind: "quick" }>; setError: (e: string | null) => void; back: () => void }) {
  const model = useModel();
  const done = useRef(false);
  useEffect(() => {
    const t = setInterval(async () => {
      if (done.current) return;
      try {
        const s = await step.api.quickConnectState(step.secret);
        if (s.Authenticated) {
          done.current = true;
          const r = await step.api.quickConnectAuthenticate(step.secret);
          if (r.AccessToken && r.User) await model.signedInWith(step.api, step.server, r.AccessToken, r.User);
        }
      } catch (e) {
        done.current = true;
        setError((e as Error).message);
      }
    }, 3000);
    return () => clearInterval(t);
  }, [step, model, setError]);
  return (
    <div className="username center">
      <p className="muted">On a device where you're signed in, open Quick Connect (in JellyReco: Settings → Quick Connect; in Jellyfin's web app: your profile → Quick Connect) and enter this code:</p>
      <div className="quick-code">{step.code}</div>
      <Spinner label="Waiting for approval…" />
      <button className="text-button" onClick={back}><Icon name="chevronLeft" size={15} /> Back</button>
    </div>
  );
}
