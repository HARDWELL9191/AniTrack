// Prevents an extra console window on Windows in release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // The AI writer's background process is this same exe (see llm/helper.rs).
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("--llm-helper") {
        std::process::exit(anitrack_lib::llm::helper::main(&args[2..]));
    }
    anitrack_lib::run()
}
