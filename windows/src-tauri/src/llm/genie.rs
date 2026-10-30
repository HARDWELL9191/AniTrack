//! Qualcomm Genie (the Snapdragon NPU's language model runtime, Genie.dll from the QAIRT
//! libraries AniReco ships), loaded at run time from the app's AI folder. Function signatures
//! follow GenieDialog.h / GenieCommon.h (QAIRT 2.4x-2.5x).

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;

type Status = i32;
type Handle = *mut c_void;
type Callback = extern "C" fn(response: *const c_char, sentence_code: u32, user_data: *const c_void);

/// GENIE_DIALOG_SENTENCE_COMPLETE: the prompt is a self-contained query.
const SENTENCE_COMPLETE: u32 = 0;

struct Api {
    _lib: libloading::Library,
    config_create_from_json: unsafe extern "C" fn(*const c_char, *mut Handle) -> Status,
    config_free: unsafe extern "C" fn(Handle) -> Status,
    dialog_create: unsafe extern "C" fn(Handle, *mut Handle) -> Status,
    dialog_query: unsafe extern "C" fn(Handle, *const c_char, u32, Callback, *const c_void) -> Status,
    dialog_reset: unsafe extern "C" fn(Handle) -> Status,
    dialog_free: unsafe extern "C" fn(Handle) -> Status,
    set_max_tokens: Option<unsafe extern "C" fn(Handle, u32) -> Status>,
    version: [unsafe extern "C" fn() -> u32; 3],
}

pub struct Dialog {
    api: Api,
    config: Handle,
    dialog: Handle,
}

fn status_text(code: Status) -> &'static str {
    match code {
        -1 => "general error",
        -2 => "invalid argument",
        -3 => "out of memory",
        -4 => "invalid config",
        -5 => "invalid handle",
        -6 => "query failed",
        -7 => "config isn't valid JSON",
        -8 => "config doesn't match the schema",
        -9 => "config has an invalid value",
        -10 => "generation failed",
        _ => "error",
    }
}

/// 0 = success; positive codes are warnings (e.g. the context filled up): the answer so far is
/// still good.
fn check(what: &str, code: Status) -> Result<(), String> {
    if code >= 0 {
        Ok(())
    } else {
        Err(format!("{what} failed: Genie {} ({code})", status_text(code)))
    }
}

impl Dialog {
    /// Loads Genie.dll from `lib_dir` and the model described by `bundle/genie_config.json`.
    pub fn open(lib_dir: &Path, bundle: &Path) -> Result<Self, String> {
        let name = if cfg!(windows) { "Genie.dll" } else { "libGenie.so" };
        let api = unsafe { Api::load(&lib_dir.join(name))? };
        let json = std::fs::read_to_string(bundle.join("genie_config.json")).map_err(|e| format!("genie_config.json: {e}"))?;
        let json = CString::new(json).map_err(|e| e.to_string())?;
        // The config names its files relative to its own folder.
        std::env::set_current_dir(bundle).map_err(|e| e.to_string())?;
        let mut config: Handle = std::ptr::null_mut();
        check("Reading the model config", unsafe { (api.config_create_from_json)(json.as_ptr(), &mut config) })?;
        let mut dialog: Handle = std::ptr::null_mut();
        let created = unsafe { (api.dialog_create)(config, &mut dialog) };
        if let Err(e) = check("Loading the model onto the NPU", created) {
            unsafe { (api.config_free)(config) };
            return Err(e);
        }
        Ok(Self { api, config, dialog })
    }

    pub fn version(&self) -> String {
        let [a, b, c] = self.api.version.map(|f| unsafe { f() });
        format!("{a}.{b}.{c}")
    }

    /// Generates a reply to `prompt` (already in the model's chat format), at most `max_tokens`.
    pub fn generate(&mut self, prompt: &str, max_tokens: u32) -> Result<String, String> {
        unsafe {
            (self.api.dialog_reset)(self.dialog);
            if let Some(set) = self.api.set_max_tokens {
                set(self.dialog, max_tokens);
            }
        }
        let prompt = CString::new(prompt).map_err(|e| e.to_string())?;
        let mut out = String::new();
        let rc = unsafe {
            (self.api.dialog_query)(self.dialog, prompt.as_ptr(), SENTENCE_COMPLETE, collect, &mut out as *mut String as *const c_void)
        };
        check("Writing", rc)?;
        Ok(out)
    }
}

/// Genie calls this (on the same thread, during the query) with each piece of the reply.
extern "C" fn collect(response: *const c_char, _sentence_code: u32, user_data: *const c_void) {
    if response.is_null() || user_data.is_null() {
        return;
    }
    let out = unsafe { &mut *(user_data as *mut String) };
    out.push_str(&unsafe { CStr::from_ptr(response) }.to_string_lossy());
}

impl Drop for Dialog {
    fn drop(&mut self) {
        unsafe {
            (self.api.dialog_free)(self.dialog);
            (self.api.config_free)(self.config);
        }
    }
}

impl Api {
    unsafe fn load(path: &Path) -> Result<Self, String> {
        let lib = unsafe { libloading::Library::new(path) }.map_err(|e| format!("couldn't load {}: {e}", path.display()))?;
        macro_rules! sym {
            ($name:literal) => {
                *unsafe { lib.get(concat!($name, "\0").as_bytes()) }.map_err(|e| format!("Genie has no {}: {e}", $name))?
            };
        }
        let set_max_tokens = unsafe { lib.get(b"GenieDialog_setMaxNumTokens\0") }.ok().map(|s| *s);
        Ok(Self {
            config_create_from_json: sym!("GenieDialogConfig_createFromJson"),
            config_free: sym!("GenieDialogConfig_free"),
            dialog_create: sym!("GenieDialog_create"),
            dialog_query: sym!("GenieDialog_query"),
            dialog_reset: sym!("GenieDialog_reset"),
            dialog_free: sym!("GenieDialog_free"),
            set_max_tokens,
            version: [sym!("Genie_getApiMajorVersion"), sym!("Genie_getApiMinorVersion"), sym!("Genie_getApiPatchVersion")],
            _lib: lib,
        })
    }
}
