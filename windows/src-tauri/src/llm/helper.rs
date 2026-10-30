//! `anitrack.exe --llm-helper <ai folder> <model folder>`: the background process that holds the
//! language model on the NPU. One JSON request per line on stdin, one reply per line on stdout:
//!   {"cmd":"explain","system":"…","user":"…","maxTokens":120} -> {"ok":true,"text":"…"}
//!   {"cmd":"status"}                                        -> {"ok":true,"genie":"1.x.y"}
//! The model loads on the first request; the process exits when its input closes.

use super::genie::Dialog;
use std::io::{BufRead, Write};
use std::path::PathBuf;

/// Qwen3's chat format.
pub fn chat_prompt(system: &str, user: &str) -> String {
    format!("<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n")
}

/// Strips anything the model adds after its answer and stray chat markers.
pub fn clean_reply(text: &str) -> String {
    let text = text.split("<|im_end|>").next().unwrap_or("");
    text.replace("<|im_start|>assistant", "").trim().trim_matches('"').trim().to_string()
}

pub fn main(args: &[String]) -> i32 {
    let (Some(lib_dir), Some(bundle)) = (args.first().map(PathBuf::from), args.get(1).map(PathBuf::from)) else {
        eprintln!("usage: --llm-helper <ai folder> <model folder>");
        return 2;
    };
    prepare_libraries(&lib_dir);

    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout().lock();
    let mut dialog: Option<Result<Dialog, String>> = None;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<serde_json::Value>(&line) {
            Err(e) => serde_json::json!({ "ok": false, "error": format!("bad request: {e}") }),
            Ok(req) => {
                let d = dialog.get_or_insert_with(|| Dialog::open(&lib_dir, &bundle));
                match (req["cmd"].as_str(), d) {
                    (_, Err(e)) => serde_json::json!({ "ok": false, "error": e.clone() }),
                    (Some("status"), Ok(d)) => serde_json::json!({ "ok": true, "genie": d.version() }),
                    (Some("explain"), Ok(d)) => {
                        let prompt = chat_prompt(req["system"].as_str().unwrap_or(""), req["user"].as_str().unwrap_or(""));
                        let max = req["maxTokens"].as_u64().unwrap_or(120).clamp(16, 512) as u32;
                        match d.generate(&prompt, max) {
                            Ok(text) => serde_json::json!({ "ok": true, "text": clean_reply(&text) }),
                            Err(e) => serde_json::json!({ "ok": false, "error": e }),
                        }
                    }
                    _ => serde_json::json!({ "ok": false, "error": "unknown command" }),
                }
            }
        };
        if writeln!(stdout, "{reply}").and_then(|_| stdout.flush()).is_err() {
            break;
        }
    }
    0
}

/// Genie loads QnnHtp.dll / QnnSystem.dll by name and the NPU-side libraries through
/// ADSP_LIBRARY_PATH; both live in AniTrack's AI folder.
fn prepare_libraries(lib_dir: &std::path::Path) {
    // SAFETY: called at the start of this single-purpose process, before any other thread exists.
    unsafe { std::env::set_var("ADSP_LIBRARY_PATH", lib_dir) };
    let path = std::env::var_os("PATH").unwrap_or_default();
    let mut dirs = vec![lib_dir.to_path_buf()];
    dirs.extend(std::env::split_paths(&path));
    if let Ok(joined) = std::env::join_paths(dirs) {
        unsafe { std::env::set_var("PATH", joined) };
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let wide: Vec<u16> = lib_dir.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        unsafe { windows_sys::Win32::System::LibraryLoader::SetDllDirectoryW(wide.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_and_reply() {
        assert_eq!(
            chat_prompt("Be brief.", "Why?"),
            "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nWhy?<|im_end|>\n<|im_start|>assistant\n"
        );
        assert_eq!(clean_reply("  \"You'll love it.\"<|im_end|>\nextra"), "You'll love it.");
        assert_eq!(clean_reply("Plain answer."), "Plain answer.");
    }
}
