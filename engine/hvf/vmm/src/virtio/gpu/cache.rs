//! The engine's GPU shader cache (GPU mode): where compiled shaders outlive
//! the engine, in `~/Library/Caches/Avo/gpu-cache/<key>/metal`.
//!
//! A shader's first use goes through ANGLE in the guest (GLSL to SPIR-V),
//! MoltenVK (SPIR-V to MSL) and then Metal, which compiles MSL to AIR and AIR
//! to the GPU's code; Metal is most of it. Android keeps the first two per
//! app in the app's EGL blob cache on the data disk. Metal keeps the last in
//! its own shader cache, which it puts in the process's bundle folder of
//! `DARWIN_USER_CACHE_DIR` unless told otherwise: for avo-vmm, inside Avo.app,
//! that is Avo.app's (shared with the Control Panel and every other engine of
//! that copy), without any limit Avo could see or clear on its own. The
//! engine moves it here (`MTLSetShaderCachePath`, before gfxstream starts),
//! one folder per key: emulator revision (its MoltenVK), Vulkan driver, GPU
//! and macOS build. Metal versions its files inside on its own; the key lets
//! a new emulator or macOS start clean and the old folders go.
//!
//! Limits: each of Metal's cache files at most [`METAL_FILE_LIMIT`]
//! (`MTL_SHADER_CACHE_SIZE`; Metal's default is 1 GiB per file, one
//! libraries and one functions file per engine using the folder at once),
//! and at every start everything under the root at most [`LIMIT`]: other
//! keys go when unused for [`UNUSED`] or, oldest first, when over the limit.
//!
//! `AVO_GPU_CACHE_DIR` names another root; `off` keeps Metal's default
//! place. The daemon's "Clear GPU cache" removes the root
//! (`GPUCache.swift` in AvoDaemonCore).

use std::ffi::{CStr, c_char, c_void};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

/// Everything under the cache root, at most (enforced when the engine starts).
pub const LIMIT: u64 = 2 << 30;
/// Each of Metal's cache files at most.
pub const METAL_FILE_LIMIT: u64 = 512 << 20;
/// Other keys nobody used for this long go.
pub const UNUSED: Duration = Duration::from_secs(30 * 24 * 3600);
/// Touched at every start: when a key was last used.
const STAMP: &str = "last-used";

/// `~/Library/Caches/Avo/gpu-cache`, `$AVO_GPU_CACHE_DIR`, or None (`off`).
pub fn root() -> Option<PathBuf> {
    match std::env::var_os("AVO_GPU_CACHE_DIR") {
        Some(dir) if dir == "off" => None,
        Some(dir) if !dir.is_empty() => Some(PathBuf::from(dir)),
        _ => std::env::var_os("HOME").map(|home| Path::new(&home).join("Library/Caches/Avo/gpu-cache")),
    }
}

/// `Pkg.Revision` of the emulator's `source.properties` ("37.1.11").
pub fn emulator_revision(emulator: &Path) -> Option<String> {
    let text = std::fs::read_to_string(emulator.join("source.properties")).ok()?;
    text.lines().find_map(|line| line.strip_prefix("Pkg.Revision=")).map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn sanitize(text: &str) -> String {
    let mut out: String = text
        .trim()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '.' { c.to_ascii_lowercase() } else { '-' })
        .collect();
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    out.trim_matches('-').to_string()
}

/// The folder name for one emulator, Vulkan driver, GPU and macOS build.
pub fn key(revision: &str, icd: &str, gpu: &str, os_build: &str) -> String {
    let part = |text: &str| Some(sanitize(text)).filter(|s| !s.is_empty()).unwrap_or_else(|| "unknown".into());
    format!("emulator-{}_{}_{}_macos-{}", part(revision), part(icd), part(gpu), part(os_build))
}

fn sysctl_string(name: &CStr) -> Option<String> {
    let mut buffer = [0u8; 256];
    let mut len = buffer.len();
    let ok = unsafe { libc::sysctlbyname(name.as_ptr(), buffer.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) } == 0;
    let text = CStr::from_bytes_until_nul(&buffer).ok()?.to_string_lossy().trim().to_string();
    (ok && !text.is_empty()).then_some(text)
}

/// Bytes under `path` (symbolic links not followed).
pub fn size(path: &Path) -> u64 {
    let Ok(meta) = std::fs::symlink_metadata(path) else { return 0 };
    if !meta.is_dir() {
        return meta.len();
    }
    std::fs::read_dir(path).map(|entries| entries.flatten().map(|e| size(&e.path())).sum()).unwrap_or(0)
}

/// When a key folder was last used: its stamp, else the folder itself.
fn last_used(dir: &Path) -> SystemTime {
    let modified = |p: &Path| std::fs::metadata(p).and_then(|m| m.modified()).ok();
    modified(&dir.join(STAMP)).or_else(|| modified(dir)).unwrap_or(SystemTime::UNIX_EPOCH)
}

/// Removes other keys under `root` unused for `unused`, then, oldest first,
/// until everything fits in `limit`; the folder `keep` itself is emptied
/// only when it alone is over the limit. Returns what was removed.
pub fn prune(root: &Path, keep: &str, limit: u64, unused: Duration, now: SystemTime) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else { return removed };
    let mut others: Vec<(SystemTime, PathBuf, u64)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_name() == keep || !entry.file_type().is_ok_and(|t| t.is_dir()) {
            continue;
        }
        let used = last_used(&path);
        if now.duration_since(used).unwrap_or_default() >= unused {
            if std::fs::remove_dir_all(&path).is_ok() {
                removed.push(path);
            }
            continue;
        }
        let bytes = size(&path);
        others.push((used, path, bytes));
    }
    let current = root.join(keep);
    let mut total = size(&current) + others.iter().map(|(_, _, bytes)| bytes).sum::<u64>();
    others.sort();
    for (_, path, bytes) in others {
        if total <= limit {
            break;
        }
        if std::fs::remove_dir_all(&path).is_ok() {
            total -= bytes;
            removed.push(path);
        }
    }
    if total > limit && current.is_dir() && std::fs::remove_dir_all(&current).is_ok() {
        removed.push(current);
    }
    removed
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFStringCreateWithBytes(alloc: *const c_void, bytes: *const u8, len: isize, encoding: u32, external: u8) -> *const c_void;
    fn CFStringGetCString(string: *const c_void, buffer: *mut c_char, size: isize, encoding: u32) -> u8;
    fn CFRelease(object: *const c_void);
}

const UTF8: u32 = 0x0800_0100;

/// Metal's SPI for its shader cache folder (Metal.framework exports both;
/// they take and give an NSString, toll-free bridged to CFString).
fn metal_functions() -> Option<(unsafe extern "C" fn(*const c_void), unsafe extern "C" fn() -> *const c_void)> {
    let metal = unsafe { libc::dlopen(c"/System/Library/Frameworks/Metal.framework/Metal".as_ptr(), libc::RTLD_NOW | libc::RTLD_GLOBAL) };
    if metal.is_null() {
        return None;
    }
    let set = unsafe { libc::dlsym(metal, c"MTLSetShaderCachePath".as_ptr()) };
    let get = unsafe { libc::dlsym(metal, c"MTLGetShaderCachePath".as_ptr()) };
    if set.is_null() || get.is_null() {
        return None;
    }
    // SAFETY: void MTLSetShaderCachePath(NSString *), NSString *MTLGetShaderCachePath(void).
    unsafe { Some((std::mem::transmute::<*mut c_void, _>(set), std::mem::transmute::<*mut c_void, _>(get))) }
}

/// Metal's shader cache folder for this process, if Metal says.
pub fn metal_cache_path() -> Option<PathBuf> {
    let (_, get) = metal_functions()?;
    let string = unsafe { get() };
    if string.is_null() {
        return None;
    }
    let mut buffer = vec![0 as c_char; 4096];
    (unsafe { CFStringGetCString(string, buffer.as_mut_ptr(), buffer.len() as isize, UTF8) } != 0)
        .then(|| PathBuf::from(unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_string_lossy().into_owned()))
}

/// Points Metal's shader cache at `dir`; must run before this process uses
/// Metal (Metal keeps the folder it first used).
pub fn set_metal_cache_path(dir: &Path) -> Result<(), String> {
    let (set, _) = metal_functions().ok_or("Metal has no MTLSetShaderCachePath")?;
    let bytes = dir.as_os_str().as_encoded_bytes();
    let string = unsafe { CFStringCreateWithBytes(std::ptr::null(), bytes.as_ptr(), bytes.len() as isize, UTF8, 0) };
    if string.is_null() {
        return Err("not a UTF-8 path".into());
    }
    // Metal copies the path.
    unsafe {
        set(string);
        CFRelease(string);
    }
    match metal_cache_path() {
        Some(path) if path == dir => Ok(()),
        other => Err(format!("Metal kept {}", other.map(|p| p.display().to_string()).unwrap_or_else(|| "its own folder".into()))),
    }
}

/// Picks and prunes the folder, sets Metal's limit and points Metal at it.
/// Returns the Metal folder, or None when the cache is off or unusable
/// (Metal then keeps its default place).
///
/// # Safety
/// Changes the process environment: call it before any thread starts.
pub unsafe fn prepare(emulator: &Path) -> Option<PathBuf> {
    let root = root()?;
    let revision = emulator_revision(emulator).unwrap_or_default();
    let icd = std::env::var("ANDROID_EMU_VK_ICD").unwrap_or_default();
    let gpu = sysctl_string(c"machdep.cpu.brand_string").unwrap_or_default();
    let os = sysctl_string(c"kern.osversion").unwrap_or_default();
    let key = key(&revision, &icd, &gpu, &os);
    let removed = prune(&root, &key, LIMIT, UNUSED, SystemTime::now());
    for path in &removed {
        eprintln!("[gpu] shader cache: removed {}", path.display());
    }
    let dir = root.join(&key);
    let metal = dir.join("metal");
    if let Err(e) = std::fs::create_dir_all(&metal) {
        eprintln!("[gpu] shader cache: {}: {e}", metal.display());
        return None;
    }
    let about = format!(
        "Avo's GPU shader cache (avo-vmm, docs/engine.md)\nemulator: {} ({revision})\nvulkan driver: {icd}\ngpu: {gpu}\nmacos: {os}\n",
        emulator.display()
    );
    let _ = std::fs::write(dir.join(STAMP), about);
    if std::env::var_os("MTL_SHADER_CACHE_SIZE").is_none() {
        unsafe { std::env::set_var("MTL_SHADER_CACHE_SIZE", METAL_FILE_LIMIT.to_string()) };
    }
    match set_metal_cache_path(&metal) {
        Ok(()) => {
            eprintln!("[gpu] shader cache {} ({} MiB)", dir.display(), size(&dir) >> 20);
            Some(metal)
        }
        Err(e) => {
            eprintln!("[gpu] shader cache: {e}");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("avo-gpu-cache-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn fill(dir: &Path, bytes: usize) {
        std::fs::create_dir_all(dir.join("metal/32024")).unwrap();
        std::fs::write(dir.join("metal/32024/libraries.data"), vec![0u8; bytes]).unwrap();
        std::fs::write(dir.join(STAMP), b"").unwrap();
    }

    #[test]
    fn the_key_names_emulator_driver_gpu_and_macos() {
        assert_eq!(key("37.1.11", "moltenvk", "Apple M4 Pro", "26A434"), "emulator-37.1.11_moltenvk_apple-m4-pro_macos-26a434");
        assert_eq!(key("", "", " ", "x/y"), "emulator-unknown_unknown_unknown_macos-x-y");
    }

    #[test]
    fn the_revision_comes_from_source_properties() {
        let dir = scratch("revision");
        assert_eq!(emulator_revision(&dir), None);
        std::fs::write(dir.join("source.properties"), "Pkg.UserSrc=false\nPkg.Revision=37.1.11\nPkg.Path=emulator\n").unwrap();
        assert_eq!(emulator_revision(&dir).as_deref(), Some("37.1.11"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pruning_keeps_the_current_key_and_drops_old_or_oversized_others() {
        let root = scratch("prune");
        fill(&root.join("current"), 1000);
        fill(&root.join("older"), 3000);
        fill(&root.join("newer"), 3000);
        let now = SystemTime::now();
        let set_used = |name: &str, at: SystemTime| {
            std::fs::File::options().write(true).open(root.join(name).join(STAMP)).unwrap().set_modified(at).unwrap();
        };
        set_used("older", now - Duration::from_secs(3600));
        set_used("newer", now - Duration::from_secs(60));
        // Under the limit and recently used: everything stays.
        assert!(prune(&root, "current", 1 << 20, UNUSED, now).is_empty());
        // Over the limit: the least recently used other key goes first.
        assert_eq!(prune(&root, "current", 5000, UNUSED, now), vec![root.join("older")]);
        assert!(root.join("newer").is_dir() && root.join("current").is_dir());
        // Unused for long enough: gone whatever the size.
        assert_eq!(prune(&root, "current", 1 << 20, Duration::from_secs(30), now), vec![root.join("newer")]);
        // The current key alone over the limit starts again.
        assert_eq!(prune(&root, "current", 10, UNUSED, now), vec![root.join("current")]);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_root_follows_the_environment() {
        // Only this test changes AVO_GPU_CACHE_DIR in the test process, and puts it back.
        let before = std::env::var_os("AVO_GPU_CACHE_DIR");
        unsafe { std::env::set_var("AVO_GPU_CACHE_DIR", "/tmp/elsewhere") };
        assert_eq!(root(), Some(PathBuf::from("/tmp/elsewhere")));
        unsafe { std::env::set_var("AVO_GPU_CACHE_DIR", "off") };
        assert_eq!(root(), None);
        unsafe { std::env::remove_var("AVO_GPU_CACHE_DIR") };
        assert!(root().unwrap().ends_with("Library/Caches/Avo/gpu-cache"));
        if let Some(value) = before {
            unsafe { std::env::set_var("AVO_GPU_CACHE_DIR", value) };
        }
    }

    #[test]
    fn metal_takes_the_cache_folder() {
        let dir = scratch("metal");
        set_metal_cache_path(&dir).unwrap();
        assert_eq!(metal_cache_path(), Some(dir.clone()));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
