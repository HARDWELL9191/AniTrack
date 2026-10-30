//! "Why would I like this?" with Windows' on-device language model (the Windows twin of the
//! iPhone's Apple Intelligence explainer).
//!
//! Windows only lets apps with a package identity use its language model (Phi Silica on
//! Copilot+ PCs, replaced by Aion Instruct in January 2027 behind the same API), so the model
//! is used through AniTrack's small AI helper (`ai-helper/AniTrack.AI.exe`), which gets its
//! identity from the AniTrack.WindowsAI package. The installer trusts that package's
//! certificate; the package itself is registered here, for the signed-in user, the first time
//! it's needed (and again after an update).
//!
//! The helper only runs while explanations are being written: it starts on the first request
//! and is closed after a minute without one, so the model isn't kept in memory.

use serde::Serialize;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const IDLE: Duration = Duration::from_secs(60);

#[derive(Clone, Serialize)]
pub struct Status {
    pub available: bool,
    pub detail: String,
}

struct Helper {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

pub struct WinAi {
    /// The install folder (the package's external location).
    root: PathBuf,
    /// Where the "registered version" note is kept.
    data: PathBuf,
    helper: Mutex<Option<Helper>>,
    last_used: Mutex<Instant>,
    status: Mutex<Option<Status>>,
}

impl WinAi {
    pub fn new(root: PathBuf, data: PathBuf) -> Self {
        // Plain paths for Add-AppxPackage (no \\?\ prefix).
        let plain = |p: PathBuf| match p.to_str().and_then(|s| s.strip_prefix(r"\\?\")) {
            Some(rest) => PathBuf::from(rest),
            None => p,
        };
        let (root, data) = (plain(root), plain(data));
        Self { root, data, helper: Mutex::new(None), last_used: Mutex::new(Instant::now()), status: Mutex::new(None) }
    }

    fn files_present(&self) -> bool {
        self.root.join("ai-helper").join("AniTrack.AI.exe").exists() && self.root.join("winai").join("AniTrack.AI.msix").exists()
    }

    /// Whether explanations can be written on this PC (checked once per launch).
    pub fn status(&self) -> Status {
        if let Some(s) = self.status.lock().unwrap().clone() {
            return s;
        }
        let s = self.check();
        *self.status.lock().unwrap() = Some(s.clone());
        s
    }

    fn check(&self) -> Status {
        let off = |detail: &str| Status { available: false, detail: detail.into() };
        if !cfg!(windows) {
            return off("Windows AI is only on Windows.");
        }
        if !self.files_present() {
            return off("Windows AI files are missing; reinstall AniTrack.");
        }
        if let Err(e) = self.ensure_registered() {
            return off(&format!("Couldn't set up Windows AI: {e}"));
        }
        match self.request(&serde_json::json!({ "cmd": "status" })) {
            Ok(reply) => match reply["state"].as_str().unwrap_or("") {
                "Ready" | "NotReady" => Status { available: true, detail: "Windows AI on the Snapdragon NPU (on-device)".into() },
                "NotSupportedOnCurrentSystem" => off("This PC doesn't have Windows' on-device language model (Copilot+ PCs only)."),
                "DisabledByUser" => off("Windows' on-device AI is turned off in Settings (Privacy & security)."),
                "CapabilityMissing" => off(&match reply["identity"].as_str() {
                    Some(id) => format!("Windows didn't give AniTrack ({id}) permission to use its language model."),
                    None => "Windows didn't recognize AniTrack's app identity; reinstall AniTrack.".to_string(),
                }),
                other => off(&format!("Windows' language model isn't available ({other}).")),
            },
            Err(e) => off(&format!("Windows AI didn't start: {e}")),
        }
    }

    /// Two short sentences about why you'd like the show.
    pub fn explain(&self, prompt: &str) -> Result<String, String> {
        let reply = self.request(&serde_json::json!({ "cmd": "explain", "prompt": prompt }))?;
        reply["text"].as_str().map(str::to_string).ok_or_else(|| "no text".into())
    }

    fn request(&self, req: &serde_json::Value) -> Result<serde_json::Value, String> {
        let mut guard = self.helper.lock().unwrap();
        *self.last_used.lock().unwrap() = Instant::now();
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = Some(self.spawn()?);
            }
            let helper = guard.as_mut().unwrap();
            let sent = writeln!(helper.stdin, "{req}").and_then(|_| helper.stdin.flush());
            let mut line = String::new();
            let read = sent.and_then(|_| helper.stdout.read_line(&mut line));
            match read {
                Ok(n) if n > 0 => {
                    *self.last_used.lock().unwrap() = Instant::now();
                    let reply: serde_json::Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
                    return if reply["ok"].as_bool() == Some(true) {
                        Ok(reply)
                    } else {
                        Err(reply["error"].as_str().unwrap_or("unknown error").to_string())
                    };
                }
                // The helper went away (closed while idle, or crashed): start it again once.
                _ => {
                    if let Some(mut h) = guard.take() {
                        let _ = h.child.kill();
                        let _ = h.child.wait();
                    }
                    if attempt == 1 {
                        return Err("the AI helper stopped unexpectedly".into());
                    }
                }
            }
        }
        unreachable!()
    }

    fn spawn(&self) -> Result<Helper, String> {
        let mut cmd = Command::new(self.root.join("ai-helper").join("AniTrack.AI.exe"));
        cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        no_window(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = BufReader::new(child.stdout.take().ok_or("no stdout")?);
        Ok(Helper { child, stdin, stdout })
    }

    /// Called every few seconds: closes the helper (and with it the model) after a quiet minute.
    pub fn close_if_idle(&self) {
        let Ok(mut guard) = self.helper.try_lock() else { return };
        if guard.is_some() && self.last_used.lock().unwrap().elapsed() > IDLE {
            if let Some(mut h) = guard.take() {
                drop(h.stdin); // the helper exits when its input closes
                let _ = h.child.wait_timeout_or_kill(Duration::from_secs(3));
            }
        }
    }

    /// Registers the identity package for this user (no admin rights needed) when it isn't yet
    /// registered at this version.
    fn ensure_registered(&self) -> Result<(), String> {
        let version = std::fs::read_to_string(self.root.join("winai").join("version.txt")).map_err(|e| e.to_string())?;
        let version = version.trim();
        let note = self.data.join("winai-registered.txt");
        if std::fs::read_to_string(&note).ok().as_deref() == Some(version) {
            return Ok(());
        }
        let msix = self.root.join("winai").join("AniTrack.AI.msix");
        let script = format!(
            "$ErrorActionPreference='Stop'; Add-AppxPackage -Path {} -ExternalLocation {} -ForceUpdateFromAnyVersion",
            ps_quote(&msix),
            ps_quote(&self.root)
        );
        let out = powershell(&script)?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr);
            let first = err.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("Add-AppxPackage failed");
            return Err(first.to_string());
        }
        let _ = std::fs::create_dir_all(&self.data);
        let _ = std::fs::write(&note, version);
        Ok(())
    }
}

fn powershell(script: &str) -> Result<std::process::Output, String> {
    let mut cmd = Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script]);
    no_window(&mut cmd);
    cmd.output().map_err(|e| e.to_string())
}

fn ps_quote(p: &Path) -> String {
    format!("'{}'", p.display().to_string().replace('\'', "''"))
}

#[cfg(windows)]
fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn no_window(_cmd: &mut Command) {}

trait WaitTimeout {
    fn wait_timeout_or_kill(&mut self, timeout: Duration) -> Result<(), ()>;
}

impl WaitTimeout for Child {
    fn wait_timeout_or_kill(&mut self, timeout: Duration) -> Result<(), ()> {
        let start = Instant::now();
        while start.elapsed() < timeout {
            if let Ok(Some(_)) = self.try_wait() {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.kill();
        let _ = self.wait();
        Err(())
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    /// A stand-in helper: answers status, explains by echoing, and quits on "crash".
    fn fake_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!("anitrack-winai-{}", std::process::id()));
        std::fs::create_dir_all(root.join("ai-helper")).unwrap();
        let exe = root.join("ai-helper").join("AniTrack.AI.exe");
        std::fs::write(
            &exe,
            r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    *status*) echo '{"ok":true,"state":"Ready"}' ;;
    *crash*) exit 3 ;;
    *explain*) echo '{"ok":true,"text":"Because you liked Frieren."}' ;;
    *) echo '{"ok":false,"error":"unknown command"}' ;;
  esac
done
"#,
        )
        .unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        root
    }

    #[test]
    fn talks_to_the_helper_and_restarts_it() {
        let root = fake_root();
        let w = WinAi::new(root.clone(), root.join("data"));
        assert_eq!(w.request(&serde_json::json!({"cmd": "status"})).unwrap()["state"], "Ready");
        assert_eq!(w.explain("why?").unwrap(), "Because you liked Frieren.");
        // The helper dies: the next request starts a new one.
        assert!(w.request(&serde_json::json!({"cmd": "crash"})).is_err());
        assert_eq!(w.explain("again").unwrap(), "Because you liked Frieren.");
        assert_eq!(w.request(&serde_json::json!({"cmd": "nope"})).unwrap_err(), "unknown command");
        // Idle: closed, and started again on demand.
        *w.last_used.lock().unwrap() = Instant::now() - Duration::from_secs(120);
        w.close_if_idle();
        assert!(w.helper.lock().unwrap().is_none());
        assert_eq!(w.explain("later").unwrap(), "Because you liked Frieren.");
        let _ = std::fs::remove_dir_all(root);
    }
}
