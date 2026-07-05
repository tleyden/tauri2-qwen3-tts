use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

use swift_rs::SwiftLinker;

fn main() {
    // Must match the `platforms: [.macOS(.v14)]` entry in qwen3-tts-swift/Package.swift --
    // MLX requires a materially newer minimum than the 10.15 used by the vision-swift
    // reference this crate is modeled on.
    SwiftLinker::new("14.0")
        .with_package("qwen3-tts-swift", "./qwen3-tts-swift/")
        .link();

    // MLX's core is C++ (exceptions, RTTI), unlike the ObjC/Swift-only vision-swift
    // reference this crate is modeled on. SwiftLinker only links the Swift runtime and
    // compiler-rt, so libc++ needs to be linked explicitly or the final binary fails with
    // undefined symbols like __cxa_throw / __gxx_personality_v0.
    println!("cargo:rustc-link-lib=c++");

    // SwiftLinker adds `-L` search paths for the Swift runtime (so the linker can resolve
    // symbols against it), but never adds an `-rpath`, so dyld can't find dylibs like
    // libswift_Concurrency.dylib at *runtime*. vision-swift never hit this because it has
    // no async code; Qwen3TTS's use of async/AsyncStream pulls in the concurrency runtime,
    // which needs this standard system rpath (the same one `swiftc` adds automatically when
    // it drives the final link itself).
    //
    // NOTE: `cargo:rustc-link-arg` (unlike rustc-link-lib/rustc-link-search) only applies to
    // *this* package's own targets -- it does not propagate to a downstream crate that just
    // depends on this one. Any binary crate linking qwen3-tts-swift-rs (e.g. a Tauri app's
    // src-tauri) must repeat this exact line in its own build.rs, or it will fail at launch
    // with the same "Library not loaded: @rpath/libswift_Concurrency.dylib" error.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");

    build_metallib();
}

/// `swift build` (used above via `SwiftLinker`) silently produces no `default.metallib` for
/// MLX: mlx-swift's `Cmlx` target declares zero `resources:` in its Package.swift and ships
/// its `.metal` kernel sources as plain target sources, relying entirely on Xcode's built-in
/// Metal-compiler build phase -- which the open-source `swift build` CLI does not replicate.
/// Confirmed empirically: a plain `swift build` here produces zero `.metallib`/`.bundle`
/// files anywhere in `.build/`, and the resulting binary fails at runtime with
/// "Failed to load the default metallib".
///
/// `xcodebuild`, in turn, does not emit a single consolidated static archive for a SwiftPM
/// library product when driven headlessly (it emits one relocatable `.o` per target instead
/// of a `lib<name>.a`), so it can't cleanly replace `swift build` for linking either.
///
/// So: keep `swift build` for compiling/linking the static library (already proven above),
/// and use `xcodebuild` for exactly the one thing it does that `swift build` doesn't --
/// compiling the Metal shaders -- then embed the resulting `default.metallib` bytes into
/// this crate so `ensure_metallib_installed()` can write it out next to the running
/// executable at startup (MLX looks for `<binary_dir>/mlx.metallib` first).
fn build_metallib() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let dest = out_dir.join("mlx.metallib");

    if dest.exists() {
        println!("cargo:rustc-env=QWEN3_TTS_METALLIB_PATH={}", dest.display());
        return;
    }

    let package_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("qwen3-tts-swift");
    let derived_data = out_dir.join("xcodebuild-metallib");
    let configuration = if env::var("DEBUG").as_deref() == Ok("true") {
        "Debug"
    } else {
        "Release"
    };

    let status = Command::new("xcodebuild")
        .current_dir(&package_dir)
        .args(["build", "-scheme", "qwen3-tts-swift"])
        .args(["-configuration", configuration])
        .args(["-destination", "platform=macOS"])
        .args(["-derivedDataPath", derived_data.to_str().unwrap()])
        .arg("-skipPackagePluginValidation")
        .status()
        .expect("failed to run xcodebuild (is Xcode installed? `xcode-select -p`)");
    if !status.success() {
        panic!("xcodebuild failed while building qwen3-tts-swift for its Metal shader library");
    }

    let bundle = derived_data
        .join("Build/Products")
        .join(configuration)
        .join("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib");
    if !bundle.exists() {
        panic!(
            "xcodebuild succeeded but default.metallib was not found at {}",
            bundle.display()
        );
    }

    std::fs::copy(&bundle, &dest).expect("failed to copy default.metallib into OUT_DIR");
    println!("cargo:rustc-env=QWEN3_TTS_METALLIB_PATH={}", dest.display());
    println!("cargo:rerun-if-changed={}", package_dir.display());
}
