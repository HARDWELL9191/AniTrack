//! The downloaded model package (Qualcomm's Genie bundle for the Snapdragon NPU): unpacking it,
//! finding its genie_config.json and the one fix it needs.

use std::fs::File;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};

/// Unpacks `zip` into `dest` (only files that stay inside `dest`) and returns the folder that
/// holds genie_config.json.
pub fn extract(zip: &Path, dest: &Path) -> Result<PathBuf, String> {
    let file = File::open(zip).map_err(|e| format!("couldn't open the download: {e}"))?;
    extract_from(file, dest)?;
    find_root(dest).ok_or_else(|| "the download has no genie_config.json".to_string())
}

fn extract_from<R: Read + Seek>(reader: R, dest: &Path) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(reader).map_err(|e| format!("the download isn't a valid zip: {e}"))?;
    std::fs::create_dir_all(dest).map_err(|e| e.to_string())?;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        // enclosed_name: no absolute paths or "..", so nothing lands outside `dest`.
        let Some(rel) = entry.enclosed_name() else { continue };
        if rel.components().any(|c| c.as_os_str() == "__MACOSX") {
            continue;
        }
        let out = dest.join(&rel);
        if entry.is_dir() {
            std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
            continue;
        }
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let mut f = File::create(&out).map_err(|e| format!("couldn't write {}: {e}", out.display()))?;
        // The zip checks each file's CRC as it's read, so a damaged download fails here.
        std::io::copy(&mut entry, &mut f).map_err(|e| format!("couldn't unpack {}: {e}", rel.display()))?;
    }
    Ok(())
}

/// The folder (dest itself or one level or two down) containing genie_config.json.
pub fn find_root(dest: &Path) -> Option<PathBuf> {
    if dest.join("genie_config.json").is_file() {
        return Some(dest.to_path_buf());
    }
    let mut dirs = vec![(dest.to_path_buf(), 0)];
    while let Some((dir, depth)) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).ok()?.flatten() {
            let path = entry.path();
            if path.is_dir() {
                if path.join("genie_config.json").is_file() {
                    return Some(path);
                }
                if depth < 2 {
                    dirs.push((path, depth + 1));
                }
            }
        }
    }
    None
}

/// Turns on graph switching for multi-graph bundles. Without it, Genie runs the long prompt
/// graph for every generated token (about 20x slower on the Qwen3 4B bundle, as measured by
/// the npurun project on Snapdragon X Elite). Leaves an explicit setting alone; harmless when
/// not needed.
pub fn patch_config(root: &Path) -> Result<(), String> {
    let path = root.join("genie_config.json");
    let raw = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let mut value: serde_json::Value = serde_json::from_str(&raw).map_err(|e| format!("genie_config.json: {e}"))?;
    let htp = value
        .get_mut("dialog")
        .and_then(|d| d.get_mut("engine"))
        .and_then(|e| e.get_mut("backend"))
        .and_then(|b| b.get_mut("QnnHtp"))
        .and_then(|h| h.as_object_mut())
        .ok_or("genie_config.json has no dialog.engine.backend.QnnHtp")?;
    if !htp.contains_key("enable-graph-switching") {
        htp.insert("enable-graph-switching".into(), serde_json::Value::Bool(true));
        let text = serde_json::to_string_pretty(&value).map_err(|e| e.to_string())?;
        std::fs::write(&path, text).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Checks the files genie_config.json points to are all there (tokenizer, NPU parts, extensions).
pub fn validate(root: &Path) -> Result<Summary, String> {
    let raw = std::fs::read_to_string(root.join("genie_config.json")).map_err(|e| e.to_string())?;
    let value: serde_json::Value = serde_json::from_str(&raw).map_err(|e| format!("genie_config.json: {e}"))?;
    let dialog = &value["dialog"];
    let mut needed: Vec<String> = Vec::new();
    if let Some(t) = dialog["tokenizer"]["path"].as_str() {
        needed.push(t.to_string());
    }
    if let Some(ext) = dialog["engine"]["backend"]["extensions"].as_str() {
        needed.push(ext.to_string());
    }
    let bins: Vec<String> = dialog["engine"]["model"]["binary"]["ctx-bins"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
        .unwrap_or_default();
    if bins.is_empty() {
        return Err("genie_config.json lists no model parts (ctx-bins)".into());
    }
    needed.extend(bins.iter().cloned());
    for rel in &needed {
        // Bundles reference files next to genie_config.json; only the file name matters.
        let name = Path::new(rel).file_name().map(|n| n.to_owned()).unwrap_or_default();
        if !root.join(rel).is_file() && !root.join(&name).is_file() {
            return Err(format!("the model is missing {rel}"));
        }
    }
    Ok(Summary {
        parts: bins.len(),
        context: dialog["context"]["size"].as_u64().unwrap_or(0),
        graph_switching: dialog["engine"]["backend"]["QnnHtp"]["enable-graph-switching"].as_bool().unwrap_or(false),
    })
}

#[derive(Debug, serde::Serialize)]
pub struct Summary {
    pub parts: usize,
    pub context: u64,
    pub graph_switching: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn sample_zip(path: &Path, config: &str, with_bins: bool) {
        let f = File::create(path).unwrap();
        let mut z = zip::ZipWriter::new(f);
        let opts = zip::write::SimpleFileOptions::default();
        z.add_directory("qwen3_bundle/", opts).unwrap();
        z.start_file("qwen3_bundle/genie_config.json", opts).unwrap();
        z.write_all(config.as_bytes()).unwrap();
        z.start_file("qwen3_bundle/tokenizer.json", opts).unwrap();
        z.write_all(b"{}").unwrap();
        z.start_file("qwen3_bundle/htp_backend_ext_config.json", opts).unwrap();
        z.write_all(b"{}").unwrap();
        if with_bins {
            for i in 1..=2 {
                z.start_file(format!("qwen3_bundle/part_{i}_of_2.bin"), opts).unwrap();
                z.write_all(&[i as u8; 64]).unwrap();
            }
        }
        z.start_file("__MACOSX/._junk", opts).unwrap();
        z.write_all(b"x").unwrap();
        z.finish().unwrap();
    }

    const CONFIG: &str = r#"{"dialog":{"context":{"size":4096},"tokenizer":{"path":"tokenizer.json"},
      "engine":{"backend":{"type":"QnnHtp","QnnHtp":{"use-mmap":true},"extensions":"htp_backend_ext_config.json"},
      "model":{"type":"binary","binary":{"ctx-bins":["part_1_of_2.bin","part_2_of_2.bin"]}}}}}"#;

    #[test]
    fn unpacks_patches_and_validates() {
        let dir = std::env::temp_dir().join(format!("anireco-bundle-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("model.zip");
        sample_zip(&zip_path, CONFIG, true);
        let root = extract(&zip_path, &dir.join("out")).unwrap();
        assert!(root.ends_with("qwen3_bundle"));
        assert!(!dir.join("out/__MACOSX").exists());
        let before = validate(&root).unwrap();
        assert!(!before.graph_switching);
        patch_config(&root).unwrap();
        patch_config(&root).unwrap(); // idempotent
        let after = validate(&root).unwrap();
        assert_eq!((after.parts, after.context, after.graph_switching), (2, 4096, true));

        // A bundle missing its model parts is refused.
        let bad = dir.join("bad.zip");
        sample_zip(&bad, CONFIG, false);
        let root = extract(&bad, &dir.join("bad")).unwrap();
        assert!(validate(&root).unwrap_err().contains("part_1_of_2.bin"));

        // A damaged download is refused.
        std::fs::write(dir.join("junk.zip"), b"not a zip").unwrap();
        assert!(extract(&dir.join("junk.zip"), &dir.join("junk")).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
