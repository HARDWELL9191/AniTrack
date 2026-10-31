fn main() {
    // Linux release builds (JELLYRECO_LINK_MPV=1, set by tools and CI): libmpv is still opened at
    // run time like on Windows, but the app is also linked to it so the AppImage bundler copies
    // libmpv and every library it needs (FFmpeg, libplacebo, libass, ...) into the AppImage.
    println!("cargo:rerun-if-env-changed=JELLYRECO_LINK_MPV");
    println!("cargo:rerun-if-env-changed=MPV_PREFIX");
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "linux" && std::env::var("JELLYRECO_LINK_MPV").is_ok_and(|v| v == "1") {
        if let Ok(prefix) = std::env::var("MPV_PREFIX") {
            println!("cargo:rustc-link-search=native={prefix}/lib");
        }
        println!("cargo:rustc-link-arg-bins=-Wl,--push-state,--no-as-needed,-lmpv,--pop-state");
    }
    tauri_build::build()
}
