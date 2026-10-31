//! On-device synopsis embeddings (the Windows twin of the iPhone's SemanticEngine).
//!
//! Model: BAAI bge-small-en-v1.5 (sentence embeddings, 384 numbers per show; MTEB 62.2 against
//! all-MiniLM-L6-v2's 56.3 at a similar size), run with ONNX Runtime.
//! Snapdragon NPU first (Qualcomm's QNN execution provider plugin, HTP backend), then the NPU with
//! the CPU covering any layer the NPU can't run, then the CPU alone. Every show is embedded once
//! and kept in a small binary file, so the model only runs for shows it hasn't seen.

mod store;
pub mod tokenizer;

use ort::memory::DeviceType;
use ort::session::builder::GraphOptimizationLevel;
use ort::session::Session;
use ort::value::Tensor;
use serde::Serialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use store::VectorStore;
use tokenizer::WordPiece;

/// Fixed shape: the NPU needs static shapes, and ~500 characters of synopsis fit in 128 tokens.
pub const SEQ_LEN: usize = 128;

/// Saved vectors; the name changes with the model, so a new model starts fresh.
const STORE_FILE: &str = "embeddings-bge-small-v1.bin";

/// Qualcomm's QNN execution provider (the onnxruntime-qnn plugin).
const QNN_EP: &str = "QNNExecutionProvider";

#[derive(Clone, Serialize)]
pub struct Status {
    /// "npu", "npu+cpu", "gpu", "cpu" or "off".
    pub backend: String,
    pub detail: String,
}

pub struct Paths {
    /// Folder with onnxruntime.dll (and the QNN libraries), model.onnx and vocab.txt.
    pub resources: PathBuf,
    /// Where the vector file and the NPU's compiled graph are kept.
    pub data: PathBuf,
}

struct Loaded {
    session: Session,
    tokenizer: WordPiece,
    inputs: Vec<String>,
    output: String,
    // Keeps the ONNX Runtime environment alive as long as the session.
    _env: ort::environment::Environment,
}

pub struct Engine {
    paths: Paths,
    model: Mutex<Option<Result<Loaded, String>>>,
    status: Mutex<Status>,
    store: Mutex<VectorStore>,
}

impl Engine {
    pub fn new(paths: Paths) -> Self {
        // Absolute folders: ONNX Runtime reads a relative plugin path from its own folder.
        let absolute = |p: PathBuf| std::path::absolute(&p).unwrap_or(p);
        let paths = Paths { resources: absolute(paths.resources), data: absolute(paths.data) };
        // Files left by the earlier model (all-MiniLM): its vectors don't mix with bge's.
        for old in ["embeddings-minilm-v1.bin", "minilm-qnn-ctx.onnx", "minilm-qnn-mixed-ctx.onnx"] {
            let _ = std::fs::remove_file(paths.data.join(old));
        }
        let store = VectorStore::open(paths.data.join(STORE_FILE));
        let ready = paths.resources.join("model.onnx").exists();
        Self {
            status: Mutex::new(Status {
                backend: if ready { "cpu".into() } else { "off".into() },
                detail: if ready { "Ready (starts the first time it's needed)".into() } else { "Model files missing".into() },
            }),
            paths,
            model: Mutex::new(None),
            store: Mutex::new(store),
        }
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap().clone()
    }

    pub fn cached(&self, ids: &[i64]) -> HashMap<i64, Vec<f32>> {
        let store = self.store.lock().unwrap();
        ids.iter().filter_map(|id| store.get(*id).map(|v| (*id, v.to_vec()))).collect()
    }

    /// Vectors for these shows; the model runs only for the ones not saved yet.
    pub fn vectors(&self, items: &[(i64, String)]) -> Result<HashMap<i64, Vec<f32>>, String> {
        let mut result = HashMap::new();
        let mut missing = Vec::new();
        {
            let store = self.store.lock().unwrap();
            for (id, text) in items {
                match store.get(*id) {
                    Some(v) => {
                        result.insert(*id, v.to_vec());
                    }
                    None => missing.push((*id, text.as_str())),
                }
            }
        }
        if missing.is_empty() {
            return Ok(result);
        }
        // Another call is starting the model or embedding: wait a while, but never forever (the
        // app falls back to ranking without the AI and asks again later).
        let started = std::time::Instant::now();
        let mut guard = loop {
            match self.model.try_lock() {
                Ok(g) => break g,
                Err(std::sync::TryLockError::Poisoned(p)) => break p.into_inner(),
                Err(std::sync::TryLockError::WouldBlock) => {
                    if started.elapsed() > std::time::Duration::from_secs(30) {
                        return Err("The on-device AI is busy (still starting). Try again in a moment.".into());
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        };
        if guard.is_none() {
            *self.status.lock().unwrap() = Status { backend: "cpu".into(), detail: "Starting (the first start prepares the model for the NPU)…".into() };
            let loaded = self.load();
            let status = match &loaded {
                Ok((_, s)) => s.clone(),
                Err(e) => Status { backend: "off".into(), detail: format!("Couldn't start: {e}") },
            };
            *self.status.lock().unwrap() = status;
            *guard = Some(loaded.map(|(l, _)| l));
        }
        let loaded = match guard.as_mut().unwrap() {
            Ok(l) => l,
            Err(e) => return Err(e.clone()),
        };
        let mut fresh = Vec::new();
        for (id, text) in missing {
            let v = embed(loaded, text)?;
            result.insert(id, v.clone());
            fresh.push((id, v));
        }
        self.store.lock().unwrap().append(&fresh);
        Ok(result)
    }

    fn load(&self) -> Result<(Loaded, Status), String> {
        let dir = &self.paths.resources;
        let dylib = dir.join(if cfg!(windows) { "onnxruntime.dll" } else { "libonnxruntime.so" });
        let env = ort::init_from(&dylib)
            .map_err(|e| format!("ONNX Runtime not found ({e})"))?
            .with_name("JellyReco")
            .build()
            .map_err(|e| e.to_string())?;
        let model = dir.join("model.onnx");
        let vocab = std::fs::read_to_string(dir.join("vocab.txt")).map_err(|e| format!("vocab.txt: {e}"))?;
        let tokenizer = WordPiece::from_vocab(&vocab)?;

        // Snapdragon NPU: Qualcomm's QNN execution provider, a plugin next to onnxruntime.dll.
        let qnn_plugin = dir.join("onnxruntime_providers_qnn.dll");
        let qnn_backend = dir.join("QnnHtp.dll");
        let mut notes = Vec::new();
        if cfg!(windows) && qnn_plugin.exists() && qnn_backend.exists() {
            match env.register_ep_library(QNN_EP, &qnn_plugin) {
                Ok(()) => {
                    // Whole model on the NPU first; then the NPU with the CPU covering any layer
                    // the NPU can't run.
                    for (backend, npu_only) in [("npu", true), ("npu+cpu", false)] {
                        match self.npu_session(&env, &model, &qnn_backend, npu_only) {
                            Ok(session) => {
                                let detail = if npu_only { "Snapdragon NPU (QNN)" } else { "Snapdragon NPU with CPU help (QNN)" };
                                return Ok((finish(session, tokenizer, env)?, Status { backend: backend.into(), detail: detail.into() }));
                            }
                            Err(e) => notes.push(format!("{backend}: {}", short_reason(&e))),
                        }
                    }
                }
                Err(e) => notes.push(format!("QNN plugin: {}", short_reason(&e.to_string()))),
            }
        }
        // Linux: any Vulkan GPU (Nvidia, AMD, Intel) through ONNX Runtime's WebGPU plugin.
        #[cfg(target_os = "linux")]
        if let Some(plugin) = ["libonnxruntime_providers_webgpu.so", "onnxruntime_providers_webgpu.so"].iter().map(|n| dir.join(n)).find(|p| p.exists()) {
            match self.gpu_session(&env, &model, &plugin) {
                Ok((session, name)) => {
                    return Ok((finish(session, tokenizer, env)?, Status { backend: "gpu".into(), detail: format!("GPU: {name} (WebGPU over Vulkan)") }));
                }
                Err(e) => notes.push(format!("GPU: {}", short_reason(&e))),
            }
        }
        let session = base_builder(&env)?
            .commit_from_file(&model)
            .map_err(|e| e.to_string())?;
        let detail = if notes.is_empty() { "CPU".to_string() } else { format!("CPU ({})", notes.join("; ")) };
        Ok((finish(session, tokenizer, env)?, Status { backend: "cpu".into(), detail }))
    }

    /// A session on the GPU through the WebGPU plugin. The plugin takes one GPU at a time, so with
    /// several (e.g. a Radeon or GeForce card plus the processor's own graphics) it gets the best one:
    /// a discrete card first.
    #[cfg(target_os = "linux")]
    fn gpu_session(&self, env: &ort::environment::Environment, model: &Path, plugin: &Path) -> Result<(Session, String), String> {
        env.register_ep_library("webgpu", plugin).map_err(|e| format!("plugin: {e}"))?;
        let is_gpu = |d: &ort::device::Device<'_>| d.ep().is_ok_and(|ep| ep.to_ascii_lowercase().contains("webgpu")) && d.hardware_device().ty() == DeviceType::GPU;
        let best = env.devices().filter(|d| is_gpu(d)).enumerate().min_by_key(|(i, d)| (gpu_rank(d), *i)).map(|(i, _)| i).ok_or("no Vulkan GPU found")?;
        let chosen = || env.devices().filter(|d| is_gpu(d)).nth(best);
        let name = chosen().map(|d| gpu_name(&d)).unwrap_or_else(|| "GPU".into());
        let options: Vec<(String, String)> = Vec::new();
        let session = base_builder(env)?
            .with_config_entry("session.disable_cpu_ep_fallback", "0")
            .map_err(|e| e.to_string())?
            .with_devices(chosen().into_iter(), Some(&options))
            .map_err(|e| e.to_string())?
            .commit_from_file(model)
            .map_err(|e| e.to_string())?;
        Ok((session, name))
    }

    fn npu_session(&self, env: &ort::environment::Environment, model: &Path, backend: &Path, npu_only: bool) -> Result<Session, String> {
        let is_npu = |d: &ort::device::Device<'_>| d.ep().is_ok_and(|ep| ep == QNN_EP) && d.hardware_device().ty() == DeviceType::NPU;
        if !env.devices().any(|d| is_npu(&d)) {
            return Err("no Snapdragon NPU found".into());
        }
        let options = vec![
            (format!("{QNN_EP}.backend_path"), backend.display().to_string()),
            // Balanced: fast enough for one synopsis at a time, easier on the battery than burst.
            (format!("{QNN_EP}.htp_performance_mode"), "balanced".to_string()),
        ];
        // The NPU compiles the model the first time (a few seconds); the compiled graph is saved
        // and reused on later launches.
        let ctx = self.paths.data.join(if npu_only { "bge-small-qnn-ctx.onnx" } else { "bge-small-qnn-mixed-ctx.onnx" });
        let builder = |save_ctx: bool| -> Result<ort::session::builder::SessionBuilder, String> {
            let mut b = base_builder(env)?;
            if npu_only {
                b = b.with_config_entry("session.disable_cpu_ep_fallback", "1").map_err(|e| e.to_string())?;
            }
            if save_ctx {
                b = b
                    .with_config_entry("ep.context_enable", "1")
                    .and_then(|b| b.with_config_entry("ep.context_file_path", ctx.display().to_string()))
                    .and_then(|b| b.with_config_entry("ep.context_embed_mode", "1"))
                    .map_err(|e| e.to_string())?;
            }
            b.with_devices(env.devices().filter(|d| is_npu(d)), Some(&options)).map_err(|e| e.to_string())
        };
        if ctx.exists() {
            match builder(false)?.commit_from_file(&ctx) {
                Ok(s) => return Ok(s),
                Err(_) => {
                    let _ = std::fs::remove_file(&ctx); // stale (driver update): compile again
                }
            }
        }
        match builder(true)?.commit_from_file(model) {
            Ok(s) => Ok(s),
            // Saving the compiled graph isn't essential: run without it rather than lose the NPU.
            Err(first) => {
                let _ = std::fs::remove_file(&ctx);
                builder(false)?.commit_from_file(model).map_err(|e| format!("{e} (first try: {first})"))
            }
        }
    }
}

fn base_builder(env: &ort::environment::Environment) -> Result<ort::session::builder::SessionBuilder, String> {
    Session::builder(env)
        .map_err(|e| e.to_string())?
        .with_optimization_level(GraphOptimizationLevel::Level3)
        // Snapdragon: 2 threads (the NPU does the work). Elsewhere: up to 4 of the CPU's cores.
        .and_then(|b| b.with_intra_threads(if cfg!(windows) { 2 } else { std::thread::available_parallelism().map(|n| n.get().clamp(1, 4)).unwrap_or(2) }))
        // Static shapes (the NPU needs them): one show at a time, 128 tokens.
        .and_then(|b| b.with_dimension_override("batch_size", 1))
        .and_then(|b| b.with_dimension_override("sequence_length", SEQ_LEN as i64))
        .map_err(|e| e.to_string())
}

fn finish(session: Session, tokenizer: WordPiece, env: ort::environment::Environment) -> Result<Loaded, String> {
    let inputs: Vec<String> = session.inputs().iter().map(|i| i.name().to_string()).collect();
    let outputs: Vec<String> = session.outputs().iter().map(|o| o.name().to_string()).collect();
    let output = outputs
        .iter()
        .find(|n| n.as_str() == "last_hidden_state" || n.as_str() == "token_embeddings")
        .or_else(|| outputs.first())
        .cloned()
        .ok_or("model has no outputs")?;
    Ok(Loaded { session, tokenizer, inputs, output, _env: env })
}

/// bge's sentence vector: the output at the first token ([CLS]), scaled to unit length.
fn embed(l: &mut Loaded, text: &str) -> Result<Vec<f32>, String> {
    let enc = l.tokenizer.encode(text, SEQ_LEN);
    let shape = [1i64, SEQ_LEN as i64];
    let mut feeds: Vec<(String, ort::session::SessionInputValue)> = Vec::new();
    for name in &l.inputs {
        let data = match name.as_str() {
            "input_ids" => enc.input_ids.clone(),
            "attention_mask" => enc.attention_mask.clone(),
            "token_type_ids" => enc.token_type_ids.clone(),
            other => return Err(format!("unexpected model input {other}")),
        };
        let tensor = Tensor::from_array((shape, data)).map_err(|e| e.to_string())?;
        feeds.push((name.clone(), tensor.into()));
    }
    let outputs = l.session.run(feeds).map_err(|e| e.to_string())?;
    let (out_shape, data) = outputs[l.output.as_str()].try_extract_tensor::<f32>().map_err(|e| e.to_string())?;
    let dims: Vec<i64> = out_shape.iter().copied().collect();
    let pooled: Vec<f32> = match dims.as_slice() {
        [1, seq, dim] if *seq >= 1 => data[..*dim as usize].to_vec(),
        [1, _dim] => data.to_vec(),
        other => return Err(format!("unexpected output shape {other:?}")),
    };
    let norm = pooled.iter().map(|x| x * x).sum::<f32>().sqrt();
    if !(norm > 0.0) {
        return Err("empty embedding".into());
    }
    Ok(pooled.iter().map(|x| x / norm).collect())
}

/// PCI vendor ids.
#[cfg(target_os = "linux")]
const AMD: u32 = 0x1002;
#[cfg(target_os = "linux")]
const NVIDIA: u32 = 0x10de;
#[cfg(target_os = "linux")]
const INTEL: u32 = 0x8086;

/// The GPU's PCI vendor id and whether ONNX Runtime found it to be a discrete card (if it says).
#[cfg(target_os = "linux")]
fn gpu_facts(d: &ort::device::Device<'_>) -> (u32, Option<bool>) {
    use ort::AsPointer;
    let hw = d.hardware_device();
    let api = ort::api();
    // SAFETY: read-only ONNX Runtime getters on a live device; the strings belong to the device.
    unsafe {
        let vendor = (api.HardwareDevice_VendorId)(hw.ptr());
        let kv = (api.HardwareDevice_Metadata)(hw.ptr());
        let discrete = if kv.is_null() {
            None
        } else {
            let v = (api.GetKeyValue)(kv, c"Discrete".as_ptr());
            (!v.is_null()).then(|| matches!(std::ffi::CStr::from_ptr(v).to_bytes(), b"1" | b"true" | b"True"))
        };
        (vendor, discrete)
    }
}

/// Lower is better: a discrete card, then a Radeon/GeForce, then other GPUs, integrated graphics last.
#[cfg(target_os = "linux")]
fn gpu_rank(d: &ort::device::Device<'_>) -> u8 {
    match gpu_facts(d) {
        (_, Some(true)) => 0,
        (AMD | NVIDIA, None) => 1,
        (_, None) => 2,
        (_, Some(false)) => 3,
    }
}

#[cfg(target_os = "linux")]
fn gpu_name(d: &ort::device::Device<'_>) -> String {
    let (vendor, _) = gpu_facts(d);
    match vendor {
        AMD => "AMD Radeon".into(),
        NVIDIA => "Nvidia GeForce".into(),
        INTEL => "Intel".into(),
        _ => d.hardware_device().vendor().unwrap_or("GPU").to_string(),
    }
}

/// A short reason for the settings page (ONNX Runtime's errors include source paths and C++ signatures).
fn short_reason(e: &str) -> String {
    let last = e.rsplit(" : ").next().unwrap_or(e);
    let t = last.trim().trim_end_matches(')').trim();
    if t.len() > 140 { format!("{}…", &t[..t.char_indices().take_while(|(i, _)| *i < 140).last().map(|(i, c)| i + c.len_utf8()).unwrap_or(0)]) } else { t.to_string() }
}
