//! CI check for the bundled libmpv: loads the exact DLL the installer ships, lists its decoders
//! and demuxers, and plays each test file to the end (no window, no sound card needed), checking
//! the tracks mpv finds. Prints one JSON report.
//! cargo run --example mpv_check -- <libmpv-2.dll> <out.json> <file1> [file2 ...]

use jellyreco_lib::mpv::ffi::{self, cstr, cstring, Api};
use std::ffi::c_char;
use std::time::{Duration, Instant};

fn get(api: &Api, h: ffi::Handle, name: &str) -> Option<String> {
    let n = cstring(name);
    unsafe {
        let p = (api.get_property_string)(h, n.as_ptr());
        if p.is_null() {
            return None;
        }
        let s = cstr(p);
        (api.free)(p as *mut _);
        s
    }
}

fn create(api: &Api) -> ffi::Handle {
    unsafe {
        let h = (api.create)();
        assert!(!h.is_null(), "mpv_create failed");
        for (k, v) in [("vo", "null"), ("ao", "null"), ("idle", "yes"), ("config", "no"), ("terminal", "no"), ("hwdec", "no"), ("load-scripts", "no"), ("ytdl", "no")] {
            let (k, v) = (cstring(k), cstring(v));
            (api.set_option_string)(h, k.as_ptr(), v.as_ptr());
        }
        let rc = (api.initialize)(h);
        assert!(rc >= 0, "mpv_initialize failed: {}", api.error(rc));
        h
    }
}

fn play(api: &Api, path: &str) -> serde_json::Value {
    let h = create(api);
    // The same observers the app uses (string format: numbers as text, lists as JSON).
    for (i, name) in ["time-pos", "pause", "track-list", "duration", "aid", "sid"].iter().enumerate() {
        let n = cstring(name);
        unsafe { (api.observe_property)(h, i as u64 + 1, n.as_ptr(), ffi::FORMAT_STRING) };
    }
    let mut property_events = 0u32;
    let mut last_time = String::new();
    let mut observed_tracks = 0usize;
    let args = [cstring("loadfile"), cstring(path)];
    let mut ptrs: Vec<*const c_char> = args.iter().map(|c| c.as_ptr()).collect();
    ptrs.push(std::ptr::null());
    let started = Instant::now();
    let rc = unsafe { (api.command)(h, ptrs.as_mut_ptr()) };
    let mut tracks = serde_json::Value::Null;
    let mut result = if rc < 0 { Some(format!("loadfile: {}", api.error(rc))) } else { None };
    let mut reason = String::new();
    let mut codecs = serde_json::Map::new();
    while result.is_none() {
        if started.elapsed() > Duration::from_secs(120) {
            result = Some("timed out".into());
            break;
        }
        let ev = unsafe { &*(api.wait_event)(h, 1.0) };
        match ev.event_id {
            ffi::EVENT_FILE_LOADED => {
                tracks = get(api, h, "track-list").and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(serde_json::Value::Null);
                for p in ["file-format", "current-tracks/video/codec", "current-tracks/audio/codec", "duration"] {
                    if let Some(v) = get(api, h, p) {
                        codecs.insert(p.into(), v.into());
                    }
                }
            }
            ffi::EVENT_END_FILE => {
                let e = unsafe { &*(ev.data as *const ffi::EventEndFile) };
                reason = match e.reason { 0 => "eof", 2 => "stop", 3 => "quit", 4 => "error", _ => "other" }.into();
                result = Some(if e.reason == 0 { String::new() } else { format!("ended: {reason} {}", if e.error < 0 { api.error(e.error) } else { String::new() }) });
            }
            ffi::EVENT_PROPERTY_CHANGE if !ev.data.is_null() => {
                let p = unsafe { &*(ev.data as *const ffi::EventProperty) };
                let name = unsafe { cstr(p.name) }.unwrap_or_default();
                let value = if p.format == ffi::FORMAT_STRING && !p.data.is_null() { unsafe { cstr(*(p.data as *const *const c_char)) } } else { None };
                property_events += 1;
                if name == "time-pos" {
                    // The furthest position reached (time-pos becomes unavailable as the file unloads).
                    if let Some(v) = &value {
                        if v.parse::<f64>().unwrap_or(0.0) >= last_time.parse::<f64>().unwrap_or(0.0) { last_time = v.clone(); }
                    }
                }
                if name == "track-list" {
                    if let Some(v) = &value {
                        // The most tracks seen while playing (newer mpv empties the list as the file unloads, before END_FILE).
                        observed_tracks = observed_tracks.max(serde_json::from_str::<Vec<serde_json::Value>>(v).map(|t| t.len()).unwrap_or(0));
                    }
                }
            }
            ffi::EVENT_SHUTDOWN => result = Some("shutdown".into()),
            _ => {}
        }
    }
    unsafe { (api.terminate_destroy)(h) };
    let error = result.unwrap_or_default();
    serde_json::json!({
        "file": path, "ok": error.is_empty(), "error": error, "reason": reason, "tracks": tracks, "info": codecs, "seconds": started.elapsed().as_secs_f32(),
        "propertyEvents": property_events, "lastTimePos": last_time, "observedTracks": observed_tracks,
    })
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (dll, out, files) = (&args[1], &args[2], &args[3..]);
    let api = Api::load(std::path::Path::new(dll)).expect("libmpv didn't load");
    let version = unsafe { (api.client_api_version)() } as u64;
    let h = create(&api);
    let decoders = get(&api, h, "decoder-list").unwrap_or_default();
    let demuxers = get(&api, h, "demuxer-lavf-list").unwrap_or_default();
    let mpv_version = get(&api, h, "mpv-version").unwrap_or_default();
    let ffmpeg_version = get(&api, h, "ffmpeg-version").unwrap_or_default();
    let hwdec = get(&api, h, "hwdec-interop").unwrap_or_default();
    unsafe { (api.terminate_destroy)(h) };
    let results: Vec<_> = files.iter().map(|f| play(&api, f)).collect();
    let report = serde_json::json!({
        "client_api": format!("{}.{}", version >> 16, version & 0xffff),
        "mpv_version": mpv_version,
        "ffmpeg_version": ffmpeg_version,
        "hwdec_interop": hwdec,
        "decoders": serde_json::from_str::<serde_json::Value>(&decoders).unwrap_or(serde_json::Value::Null),
        // A string list property reads as comma-separated text (only node properties are JSON).
        "demuxers": demuxers.split(',').map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>(),
        "files": results,
    });
    std::fs::write(out, serde_json::to_string_pretty(&report).unwrap()).expect("write report");
    println!("{}", serde_json::to_string(&report["files"]).unwrap());
}
