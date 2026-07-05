fn main() {
    // `cargo:rustc-link-arg` emitted by a dependency's build.rs (qwen3-tts-swift-rs) only
    // applies to that dependency's *own* targets, not to ours -- unlike rustc-link-lib/
    // rustc-link-search, Cargo does not propagate raw link args transitively. So the Swift
    // concurrency runtime rpath has to be repeated here for our own binary, or dyld fails at
    // launch with "Library not loaded: @rpath/libswift_Concurrency.dylib".
    #[cfg(target_os = "macos")]
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");

    tauri_build::build()
}
