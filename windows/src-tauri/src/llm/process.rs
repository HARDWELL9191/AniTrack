//! The writer's background process: AniTrack's own exe started with `--llm-helper`, talking one
//! JSON object per line over stdin/stdout. It's started on the first request and closed after a
//! quiet minute, so the language model (about 2.5 GB in the NPU's memory) is only loaded while
//! explanations are being written. A crash in it can't take the app down.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub const IDLE: Duration = Duration::from_secs(60);

struct Running {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

pub struct HelperProcess {
    exe: PathBuf,
    args: Vec<String>,
    running: Mutex<Option<Running>>,
    pub(crate) last_used: Mutex<Instant>,
}

impl HelperProcess {
    pub fn new(exe: PathBuf, args: Vec<String>) -> Self {
        Self { exe, args, running: Mutex::new(None), last_used: Mutex::new(Instant::now()) }
    }

    /// Sends one request and waits for its reply; restarts the process once if it went away.
    pub fn request(&self, req: &serde_json::Value) -> Result<serde_json::Value, String> {
        let mut guard = self.running.lock().unwrap();
        *self.last_used.lock().unwrap() = Instant::now();
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = Some(self.spawn()?);
            }
            let p = guard.as_mut().unwrap();
            let sent = writeln!(p.stdin, "{req}").and_then(|_| p.stdin.flush());
            let mut line = String::new();
            match sent.and_then(|_| p.stdout.read_line(&mut line)) {
                Ok(n) if n > 0 => {
                    *self.last_used.lock().unwrap() = Instant::now();
                    let reply: serde_json::Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
                    return if reply["ok"].as_bool() == Some(true) {
                        Ok(reply)
                    } else {
                        Err(reply["error"].as_str().unwrap_or("unknown error").to_string())
                    };
                }
                // The process went away (closed while idle, or crashed): start it again once.
                _ => {
                    if let Some(mut p) = guard.take() {
                        let _ = p.child.kill();
                        let _ = p.child.wait();
                    }
                    if attempt == 1 {
                        return Err("the AI writer stopped unexpectedly".into());
                    }
                }
            }
        }
        unreachable!()
    }

    fn spawn(&self) -> Result<Running, String> {
        let mut cmd = Command::new(&self.exe);
        cmd.args(&self.args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
        no_window(&mut cmd);
        let mut child = cmd.spawn().map_err(|e| e.to_string())?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = BufReader::new(child.stdout.take().ok_or("no stdout")?);
        Ok(Running { child, stdin, stdout })
    }

    /// Closes the process (and with it the model) after a quiet minute.
    pub fn close_if_idle(&self) {
        let Ok(mut guard) = self.running.try_lock() else { return };
        if guard.is_some() && self.last_used.lock().unwrap().elapsed() > IDLE {
            self.close(&mut guard);
        }
    }

    /// Closes it now (e.g. before the model files are removed).
    pub fn close_now(&self) {
        let mut guard = self.running.lock().unwrap();
        self.close(&mut guard);
    }

    #[cfg(test)]
    pub fn is_running(&self) -> bool {
        self.running.lock().map(|g| g.is_some()).unwrap_or(true)
    }

    fn close(&self, guard: &mut Option<Running>) {
        if let Some(mut p) = guard.take() {
            drop(p.stdin); // the helper exits when its input closes
            let start = Instant::now();
            while start.elapsed() < Duration::from_secs(3) {
                if let Ok(Some(_)) = p.child.try_wait() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let _ = p.child.kill();
            let _ = p.child.wait();
        }
    }
}

#[cfg(windows)]
fn no_window(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW);
}

#[cfg(not(windows))]
fn no_window(_cmd: &mut Command) {}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn talks_restarts_and_closes() {
        let dir = std::env::temp_dir().join(format!("anitrack-proc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("helper.sh");
        std::fs::write(
            &exe,
            "#!/bin/sh\nwhile IFS= read -r line; do\n  case \"$line\" in\n    *crash*) exit 3 ;;\n    *explain*) echo '{\"ok\":true,\"text\":\"hi\"}' ;;\n    *) echo '{\"ok\":false,\"error\":\"unknown command\"}' ;;\n  esac\ndone\n",
        )
        .unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        let p = HelperProcess::new(exe, vec![]);
        assert_eq!(p.request(&serde_json::json!({"cmd": "explain"})).unwrap()["text"], "hi");
        assert!(p.request(&serde_json::json!({"cmd": "crash"})).is_err());
        assert_eq!(p.request(&serde_json::json!({"cmd": "explain"})).unwrap()["text"], "hi");
        assert_eq!(p.request(&serde_json::json!({"cmd": "nope"})).unwrap_err(), "unknown command");
        *p.last_used.lock().unwrap() = Instant::now() - Duration::from_secs(120);
        p.close_if_idle();
        assert!(!p.is_running());
        assert_eq!(p.request(&serde_json::json!({"cmd": "explain"})).unwrap()["text"], "hi");
        let _ = std::fs::remove_dir_all(dir);
    }
}
