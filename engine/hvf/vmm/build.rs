//! Builds the host Vulkan layer that keeps gfxstream from emulating ASTC
//! (layer/native_astc.c), for astc.rs to embed and write out at start.
//!
//! On macOS: the Mac's own clang and codesign, by absolute path — Xcode's
//! avo-vmm build phase runs cargo with Xcode's environment, not the user's
//! PATH — signed ad hoc like the rest of a development build, since the vmm
//! loads it with library validation off. Elsewhere: a plain shared object
//! from the compiler in `$CC`/PATH, nothing to sign.

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let source = "layer/native_astc.c";
    println!("cargo:rerun-if-changed={source}");
    let macos = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos");
    // The artifact name follows the host OS; astc.rs takes it from here.
    let name = if macos { "libVkLayer_avo_native_astc.dylib" } else { "libVkLayer_avo_native_astc.so" };
    println!("cargo:rustc-env=AVO_ASTC_LAYER={name}");
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR")).join(name);
    if macos {
        let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
            Ok("aarch64") => "arm64".to_string(),
            Ok(other) => other.to_string(),
            Err(_) => "arm64".to_string(),
        };
        let status = Command::new("/usr/bin/clang")
            .args(["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fvisibility=hidden", "-dynamiclib", "-arch", &arch])
            .args(["-install_name", "@rpath/libVkLayer_avo_native_astc.dylib", "-o"])
            .arg(&out)
            .arg(source)
            .status()
            .expect("run /usr/bin/clang");
        assert!(status.success(), "building {source} failed");
        let status = Command::new("/usr/bin/codesign")
            .args(["--force", "--sign", "-"])
            .arg(&out)
            .status()
            .expect("run /usr/bin/codesign");
        assert!(status.success(), "signing the native ASTC layer failed");
    } else {
        let cc = std::env::var("CC").unwrap_or_else(|_| "cc".into());
        let status = Command::new(&cc)
            .args(["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-fvisibility=hidden", "-fPIC", "-shared", "-o"])
            .arg(&out)
            .arg(source)
            .status()
            .unwrap_or_else(|error| panic!("run {cc}: {error}"));
        assert!(status.success(), "building {source} failed");
    }
}
