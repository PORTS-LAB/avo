//! avo-vmm: Avo's VM engine. Boots an AOSP Cuttlefish arm64 build
//! (scripts/fetch-cuttlefish.sh) on Hypervisor.framework with crosvm-style
//! virtio-pci devices.
//!
//!   avo-vmm cuttlefish <image dir> [--instance DIR] [--runtime DIR] [--userdata FILE]
//!                       [--disks DIR] [--cpus N] [--mem MiB] [--display WxH] [--density DPI]
//!                       [--timeout SECONDS] [--properties FILE] [--verbose]
//!                       [--gpu 2d|gfxstream] [--gfxstream-dir DIR] [--hwc client|host]
//!                       [--shared-dir DIR] [--refresh-rate HZ]
//!
//! --properties names a file of key=value lines that replace the image's
//! properties (the device profile's identity, e.g. ro.product.model).
//!
//! --gpu gfxstream renders Android on the Mac's GPU with gfxstream from the
//! Android Emulator in --gfxstream-dir (the directory with lib64/); --hwc
//! host lets the composer use gfxstream's host composition (bring-up A/B).
//! Without --gpu (or with 2d) Android renders in software. Exit code 75:
//! the GPU renderer could not start, before any guest code ran.
//!
//! --refresh-rate is display 0's refresh rate (60 unless given; its EDID,
//! virtio/gpu/edid.rs). The daemon plugs every app display in at the same
//! rate: Android paces displays of different rates unevenly.
//!
//! --shared-dir gives Android a folder on the Mac (virtio-fs, tag
//! avo_shared; virtio/fs.rs), which the daemon mounts at /sdcard/Avo Shared.
//!
//! The instance directory keeps the writable disks (super, userdata,
//! metadata, misc, frp; --disks puts all but userdata elsewhere, next to
//! the data they belong with), shared-memory frames (frames/) and the logs:
//! kernel.log (earlycon, then hvc0), console.log (hvc1, the Android shell)
//! and logcat.log (hvc2). The runtime directory holds the sockets:
//! vsock.sock (guest vsock ports, docs/engine.md), control.sock (displays,
//! input, frame events; control.rs) and console.sock (the serial console).
//!
//! The guest's Wi-Fi reaches the Mac's network through user-mode NAT (net.rs).

mod android;
mod bus;
mod control;
mod cuttlefish;
mod disk;
mod fdt;
mod frames;
mod gnss;
mod machine;
mod memory;
mod modem;
mod net;
mod pause;
mod pci;
mod sensors;
mod serial;
mod sparse;
mod virtio;

use cuttlefish::Options;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;
use virtio::gpu::{GpuMode, Hwc};

const USAGE: &str = "usage: avo-vmm cuttlefish <image dir> [--instance DIR] [--runtime DIR] [--userdata FILE] [--disks DIR] [--cpus N] [--mem MiB] \
[--display WxH] [--density DPI] [--timeout S] [--properties FILE] [--verbose] [--gpu 2d|gfxstream] [--gfxstream-dir DIR] \
[--hwc client|host] [--shared-dir DIR] [--refresh-rate HZ] [--exit-on-reboot]";

/// `--gpu`, `--gfxstream-dir` and `--hwc` together.
fn gpu_mode(gpu: Option<&str>, dir: Option<PathBuf>, hwc: Option<&str>) -> Result<GpuMode, String> {
    match gpu {
        None | Some("2d") if dir.is_some() || hwc.is_some() => Err("--gfxstream-dir and --hwc need --gpu gfxstream".into()),
        None | Some("2d") => Ok(GpuMode::TwoD),
        Some("gfxstream") => Ok(GpuMode::Gfxstream {
            dir: dir.ok_or("--gpu gfxstream needs --gfxstream-dir")?,
            hwc: match hwc {
                None | Some("client") => Hwc::Client,
                Some("host") => Hwc::Host,
                Some(other) => return Err(format!("bad --hwc {other} (client or host)")),
            },
        }),
        Some(other) => Err(format!("bad --gpu {other} (2d or gfxstream)")),
    }
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut images = None;
    let mut instance = None;
    let mut runtime = None;
    let mut userdata = None;
    let mut disks = None;
    let mut cpus = 4;
    let mut memory_mib = 4096;
    let mut display = (720, 1280);
    let mut density = 320;
    let mut timeout = None;
    let mut verbose = false;
    let mut properties = None;
    let mut shared_dir = None;
    let mut exit_on_reboot = false;
    let mut refresh_rate = virtio::gpu::edid::DEFAULT_RATE;
    let (mut gpu, mut gfxstream_dir, mut hwc) = (None, None, None);
    let mut i = 0;
    while i < args.len() {
        let value = |i: usize| args.get(i + 1).cloned().ok_or(format!("{} needs a value", args[i]));
        match args[i].as_str() {
            "--instance" => instance = Some(PathBuf::from(value(i)?)),
            "--runtime" => runtime = Some(PathBuf::from(value(i)?)),
            "--userdata" => userdata = Some(PathBuf::from(value(i)?)),
            "--disks" => disks = Some(PathBuf::from(value(i)?)),
            "--cpus" => cpus = value(i)?.parse().map_err(|_| "bad --cpus")?,
            "--mem" => memory_mib = value(i)?.parse().map_err(|_| "bad --mem")?,
            "--density" => density = value(i)?.parse().map_err(|_| "bad --density")?,
            "--display" => {
                let text = value(i)?;
                let (w, h) = text.split_once('x').ok_or("bad --display (WxH)")?;
                display = (w.parse().map_err(|_| "bad --display")?, h.parse().map_err(|_| "bad --display")?);
            }
            "--timeout" => timeout = Some(Duration::from_secs(value(i)?.parse().map_err(|_| "bad --timeout")?)),
            "--properties" => properties = Some(PathBuf::from(value(i)?)),
            "--gpu" => gpu = Some(value(i)?),
            "--gfxstream-dir" => gfxstream_dir = Some(PathBuf::from(value(i)?)),
            "--hwc" => hwc = Some(value(i)?),
            "--shared-dir" => shared_dir = Some(PathBuf::from(value(i)?)),
            "--refresh-rate" => {
                refresh_rate = value(i)?.parse().map_err(|_| "bad --refresh-rate")?;
                if !virtio::gpu::edid::RATE_RANGE.contains(&refresh_rate) {
                    return Err("--refresh-rate out of range".into());
                }
            }
            "--verbose" => {
                verbose = true;
                i += 1;
                continue;
            }
            "--exit-on-reboot" => {
                exit_on_reboot = true;
                i += 1;
                continue;
            }
            other if images.is_none() && !other.starts_with("--") => {
                images = Some(PathBuf::from(other));
                i += 1;
                continue;
            }
            other => return Err(format!("unknown argument {other}")),
        }
        i += 2;
    }
    let images = images.ok_or(USAGE)?;
    let gpu = gpu_mode(gpu.as_deref(), gfxstream_dir, hwc.as_deref())?;
    let instance = instance.unwrap_or_else(|| images.with_file_name("instance"));
    let runtime = runtime.unwrap_or_else(|| instance.clone());
    let disks = disks.unwrap_or_else(|| instance.clone());
    std::fs::create_dir_all(&runtime).map_err(|e| format!("{}: {e}", runtime.display()))?;
    Ok(Options {
        images, instance, disks, runtime, userdata, cpus, memory_mib, display, density, timeout, verbose, properties, gpu, shared_dir,
        exit_on_reboot, refresh_rate,
    })
}

fn main() -> ExitCode {
    // The daemon that starts the engine runs at utility QoS, where macOS
    // coalesces timers by tens of milliseconds and schedules behind apps;
    // the engine is the device the user is using. Threads started from here
    // on inherit the class.
    unsafe { libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INITIATED, 0) };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("cuttlefish") => parse(&args[1..]).and_then(cuttlefish::run),
        Some("vbmeta") if args.len() > 1 => android::vbmeta_chain(Path::new(&args[1])).map(|chain| println!("chained: {chain:?}")),
        _ => Err(USAGE.into()),
    };
    match result {
        // In GPU mode this leaves without static destructors (cuttlefish::exit).
        Ok(()) => cuttlefish::exit(0),
        Err(message) => {
            eprintln!("error: {message}");
            cuttlefish::exit(1)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disks_follow_the_instance_unless_given() {
        let root = std::env::temp_dir().join(format!("avo-vmm-args-{}", std::process::id()));
        let args = |extra: &[&str]| -> Vec<String> {
            let mut list = vec!["/images".to_string(), "--instance".into(), root.join("instance").display().to_string(),
                                "--runtime".into(), root.join("run").display().to_string()];
            list.extend(extra.iter().map(|s| s.to_string()));
            list
        };
        let options = parse(&args(&[])).unwrap();
        assert_eq!(options.disks, root.join("instance"));
        let options = parse(&args(&["--disks", "/Volumes/SSD/Avo Android Data/cuttlefish"])).unwrap();
        assert_eq!(options.disks, PathBuf::from("/Volumes/SSD/Avo Android Data/cuttlefish"));
        assert_eq!(options.instance, root.join("instance"));
        assert!(parse(&args(&["--disks"])).is_err(), "needs a value");
        assert_eq!(options.shared_dir, None);
        let shared = parse(&args(&["--shared-dir", "/Users/me/Avo Shared"])).unwrap();
        assert_eq!(shared.shared_dir, Some(PathBuf::from("/Users/me/Avo Shared")));
        // Reboots stay in the process unless the daemon asks otherwise.
        assert!(!options.exit_on_reboot);
        assert!(parse(&args(&["--exit-on-reboot"])).unwrap().exit_on_reboot);
        // Display 0 at 60 Hz unless the daemon picks another rate.
        assert_eq!(options.refresh_rate, 60);
        assert_eq!(parse(&args(&["--refresh-rate", "120"])).unwrap().refresh_rate, 120);
        assert!(parse(&args(&["--refresh-rate", "1000"])).is_err(), "out of range");
        assert!(parse(&args(&["--refresh-rate", "fast"])).is_err());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn gpu_flags_go_together() {
        assert_eq!(gpu_mode(None, None, None), Ok(GpuMode::TwoD));
        assert_eq!(gpu_mode(Some("2d"), None, None), Ok(GpuMode::TwoD));
        let dir = PathBuf::from("/sdk/emulator");
        assert_eq!(
            gpu_mode(Some("gfxstream"), Some(dir.clone()), None),
            Ok(GpuMode::Gfxstream { dir: dir.clone(), hwc: Hwc::Client })
        );
        assert_eq!(gpu_mode(Some("gfxstream"), Some(dir.clone()), Some("host")), Ok(GpuMode::Gfxstream { dir: dir.clone(), hwc: Hwc::Host }));
        assert!(gpu_mode(Some("gfxstream"), None, None).is_err(), "needs the emulator");
        assert!(gpu_mode(None, Some(dir.clone()), None).is_err(), "a directory without GPU mode");
        assert!(gpu_mode(None, None, Some("host")).is_err());
        assert!(gpu_mode(Some("gfxstream"), Some(dir), Some("guest")).is_err());
        assert!(gpu_mode(Some("3d"), None, None).is_err());
    }
}
