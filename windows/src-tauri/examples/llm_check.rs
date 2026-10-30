//! Build check of an AI writer model package: runs the app's own unpack, config fix and file
//! check on a downloaded Qualcomm Genie zip and prints what it found.
//! cargo run --example llm_check -- <package.zip> <scratch folder>

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (zip, dest) = (std::path::Path::new(&args[1]), std::path::Path::new(&args[2]));
    let result = (|| {
        let root = anitrack_lib::llm::extract(zip, dest)?;
        anitrack_lib::llm::patch_config(&root)?;
        let summary = anitrack_lib::llm::validate(&root)?;
        let config: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(root.join("genie_config.json")).map_err(|e| e.to_string())?)
            .map_err(|e| e.to_string())?;
        let files: Vec<String> = std::fs::read_dir(&root)
            .map_err(|e| e.to_string())?
            .flatten()
            .map(|e| format!("{} ({:.1} MB)", e.file_name().to_string_lossy(), e.metadata().map(|m| m.len()).unwrap_or(0) as f64 / 1e6))
            .collect();
        Ok::<_, String>(serde_json::json!({
            "parts": summary.parts,
            "context": summary.context,
            "graphSwitching": summary.graph_switching,
            "backend": config["dialog"]["engine"]["backend"]["type"],
            "files": files,
        }))
    })();
    let _ = std::fs::remove_dir_all(dest);
    match result {
        Ok(v) => println!("{v}"),
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}
