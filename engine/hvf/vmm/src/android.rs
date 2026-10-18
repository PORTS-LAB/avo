//! Android boot images (boot v4, init_boot, vendor_boot v4), the initrd the
//! bootloader would assemble from them, bootconfig, and the AVB vbmeta digest
//! a verified-boot bootloader passes to first-stage init.

use std::path::Path;

const PAGE: usize = 4096;

pub struct BootImages {
    /// Uncompressed arm64 `Image`.
    pub kernel: Vec<u8>,
    /// Vendor ramdisk fragments followed by the generic ramdisk.
    pub ramdisk: Vec<u8>,
    pub vendor_cmdline: String,
    pub vendor_bootconfig: String,
}

fn u32_at(data: &[u8], at: usize) -> usize {
    u32::from_le_bytes(data[at..at + 4].try_into().unwrap()) as usize
}

fn round(n: usize, to: usize) -> usize {
    n.div_ceil(to) * to
}

fn read(path: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))
}

/// boot.img or init_boot.img, header v3/v4: (kernel, ramdisk).
fn parse_boot(data: &[u8], name: &str) -> Result<(Vec<u8>, Vec<u8>), String> {
    if data.len() < PAGE || &data[0..8] != b"ANDROID!" {
        return Err(format!("{name}: not an Android boot image"));
    }
    let version = u32_at(data, 40);
    if version < 3 {
        return Err(format!("{name}: boot image header v{version} is not supported (need v3 or v4)"));
    }
    let kernel_size = u32_at(data, 8);
    let ramdisk_size = u32_at(data, 12);
    let kernel_start = PAGE;
    let ramdisk_start = kernel_start + round(kernel_size, PAGE);
    if ramdisk_start + ramdisk_size > data.len() {
        return Err(format!("{name}: truncated"));
    }
    Ok((data[kernel_start..kernel_start + kernel_size].to_vec(), data[ramdisk_start..ramdisk_start + ramdisk_size].to_vec()))
}

/// vendor_boot.img v4: (platform + dlkm ramdisk fragments, cmdline, bootconfig).
fn parse_vendor_boot(data: &[u8]) -> Result<(Vec<u8>, String, String), String> {
    if data.len() < 2128 || &data[0..8] != b"VNDRBOOT" {
        return Err("vendor_boot: not a vendor boot image".into());
    }
    let version = u32_at(data, 8);
    let page = u32_at(data, 12);
    let ramdisk_size = u32_at(data, 24);
    let cmdline = String::from_utf8_lossy(&data[28..28 + 2048]).trim_end_matches('\0').to_string();
    let header_size = u32_at(data, 2096);
    let dtb_size = u32_at(data, 2100);
    let ramdisk_start = round(header_size, page);
    let ramdisks = &data[ramdisk_start..ramdisk_start + ramdisk_size];
    if version < 4 {
        return Ok((ramdisks.to_vec(), cmdline, String::new()));
    }
    let table_size = u32_at(data, 2112);
    let entries = u32_at(data, 2116);
    let entry_size = u32_at(data, 2120);
    let bootconfig_size = u32_at(data, 2124);
    let table_start = ramdisk_start + round(ramdisk_size, page) + round(dtb_size, page);
    let bootconfig_start = table_start + round(table_size, page);
    let mut selected = Vec::new();
    for i in 0..entries {
        let entry = &data[table_start + i * entry_size..table_start + (i + 1) * entry_size];
        let (size, offset, kind) = (u32_at(entry, 0), u32_at(entry, 4), u32_at(entry, 8));
        // 1 = platform, 3 = DLKM; 2 = recovery is only for recovery boots.
        if kind != 2 {
            selected.extend_from_slice(&ramdisks[offset..offset + size]);
        }
    }
    let bootconfig = String::from_utf8_lossy(&data[bootconfig_start..bootconfig_start + bootconfig_size])
        .trim_end_matches('\0')
        .to_string();
    Ok((selected, cmdline, bootconfig))
}

pub fn load(boot: &Path, init_boot: Option<&Path>, vendor_boot: &Path) -> Result<BootImages, String> {
    let (kernel, boot_ramdisk) = parse_boot(&read(boot)?, "boot")?;
    if kernel.len() < 64 || &kernel[56..60] != b"ARM\x64" {
        return Err("boot: the kernel is not an uncompressed arm64 Image".into());
    }
    let generic_ramdisk = match init_boot {
        Some(path) => parse_boot(&read(path)?, "init_boot")?.1,
        None => boot_ramdisk,
    };
    let (mut ramdisk, vendor_cmdline, vendor_bootconfig) = parse_vendor_boot(&read(vendor_boot)?)?;
    // Concatenated compressed cpio archives; later files win.
    ramdisk.extend_from_slice(&generic_ramdisk);
    Ok(BootImages { kernel, ramdisk, vendor_cmdline, vendor_bootconfig })
}

/// An uncompressed cpio archive ("newc") of regular files, for appending to
/// the initrd: the kernel unpacks every archive of a concatenated initrd
/// into the same root, later files replacing earlier ones.
pub fn cpio_newc(files: &[(&str, &[u8])]) -> Vec<u8> {
    fn pad(out: &mut Vec<u8>) {
        while out.len() % 4 != 0 {
            out.push(0);
        }
    }
    let mut out = Vec::new();
    let trailer: (&str, &[u8]) = ("TRAILER!!!", &[]);
    for (index, (name, data)) in files.iter().chain(std::iter::once(&trailer)).enumerate() {
        let is_trailer = *name == "TRAILER!!!";
        let mode: u32 = if is_trailer { 0 } else { 0o100644 };
        let fields = [
            if is_trailer { 0 } else { 0x7a00 + index as u32 }, // inode
            mode,
            0,
            0,                     // uid, gid
            1,                     // nlink
            0,                     // mtime
            data.len() as u32,     // file size
            0,
            0,
            0,
            0,                     // dev and rdev
            name.len() as u32 + 1, // name size, with its NUL
            0,                     // check
        ];
        out.extend_from_slice(b"070701");
        for field in fields {
            out.extend_from_slice(format!("{field:08X}").as_bytes());
        }
        out.extend_from_slice(name.as_bytes());
        out.push(0);
        pad(&mut out);
        out.extend_from_slice(data);
        pad(&mut out);
    }
    out
}

/// Adds properties that override the image's (identity of the device
/// profile, docs/engine.md): first-stage init copies /adb_debug.prop to the
/// debug ramdisk when /force_debuggable exists, and property loading reads
/// it last, before anything (zygote) reads them. Only unlocked devices do
/// this, which Avo's verified boot state is.
///
/// The archive goes first: Android's ramdisks are LZ4 legacy streams, which
/// have no end marker, so anything after them would be read as LZ4.
pub fn prepend_property_overrides(initrd: &mut Vec<u8>, properties: &str) {
    if properties.trim().is_empty() {
        return;
    }
    let archive = cpio_newc(&[("force_debuggable", b""), ("adb_debug.prop", properties.as_bytes())]);
    initrd.splice(0..0, archive);
}

/// Appends bootconfig the way the kernel expects it at the end of the
/// initrd: text, NUL padding to 4 bytes, size, checksum, "#BOOTCONFIG\n".
pub fn append_bootconfig(initrd: &mut Vec<u8>, text: &str) {
    let mut data = text.as_bytes().to_vec();
    data.push(0);
    while data.len() % 4 != 0 {
        data.push(0);
    }
    let checksum = data.iter().fold(0u32, |sum, &b| sum.wrapping_add(b as u32));
    initrd.extend_from_slice(&data);
    initrd.extend_from_slice(&(data.len() as u32).to_le_bytes());
    initrd.extend_from_slice(&checksum.to_le_bytes());
    initrd.extend_from_slice(b"#BOOTCONFIG\n");
}

/// Renders key=value pairs as bootconfig text; later keys replace earlier ones.
pub fn bootconfig_text(entries: &[(String, String)]) -> String {
    let mut merged: Vec<(String, String)> = Vec::new();
    for (key, value) in entries {
        match merged.iter_mut().find(|(k, _)| k == key) {
            Some(existing) => existing.1 = value.clone(),
            None => merged.push((key.clone(), value.clone())),
        }
    }
    merged.iter().map(|(k, v)| format!("{k}=\"{v}\"\n")).collect()
}

/// Parses "key=value" lines (the vendor_boot bootconfig section).
pub fn parse_bootconfig(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.trim().to_string(), v.trim().trim_matches('"').to_string()))
        .collect()
}

// MARK: AVB

unsafe extern "C" {
    fn CC_SHA256(data: *const u8, len: u32, md: *mut u8) -> *mut u8;
}

pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut digest = [0u8; 32];
    unsafe { CC_SHA256(data.as_ptr(), data.len() as u32, digest.as_mut_ptr()) };
    digest
}

fn be64(data: &[u8], at: usize) -> usize {
    u64::from_be_bytes(data[at..at + 8].try_into().unwrap()) as usize
}

/// The vbmeta struct at the start of `data`, trimmed to its real size.
fn vbmeta_struct(data: &[u8]) -> Option<&[u8]> {
    if data.len() < 256 || &data[0..4] != b"AVB0" {
        return None;
    }
    let size = 256 + be64(data, 12) + be64(data, 20);
    data.get(..size)
}

/// vbmeta embedded in a partition through its AVB footer.
fn footer_vbmeta(data: &[u8]) -> Option<&[u8]> {
    let footer = data.get(data.len().checked_sub(64)?..)?;
    if &footer[0..4] != b"AVBf" {
        return None;
    }
    let offset = be64(footer, 20);
    let size = be64(footer, 28);
    vbmeta_struct(data.get(offset..offset + size)?)
}

/// Names of partitions chained from a vbmeta struct (chain partition descriptors).
fn chained_partitions(vbmeta: &[u8]) -> Vec<String> {
    let auth = be64(vbmeta, 12);
    let aux_start = 256 + auth;
    let descriptors_offset = be64(vbmeta, 96);
    let descriptors_size = be64(vbmeta, 104);
    let mut names = Vec::new();
    let mut at = aux_start + descriptors_offset;
    let end = at + descriptors_size;
    while at + 16 <= end && end <= vbmeta.len() {
        let tag = be64(vbmeta, at);
        let following = be64(vbmeta, at + 8);
        if tag == 4 && at + 16 + 76 <= vbmeta.len() {
            // AvbChainPartitionDescriptor: location, name length, key length, flags, reserved[60].
            let name_len = u32::from_be_bytes(vbmeta[at + 20..at + 24].try_into().unwrap()) as usize;
            let name_start = at + 16 + 76;
            if let Some(name) = vbmeta.get(name_start..name_start + name_len) {
                names.push(String::from_utf8_lossy(name).to_string());
            }
        }
        at += 16 + following;
    }
    names
}

/// What a verified-boot bootloader reports to Android: the total size and
/// SHA-256 of the top-level vbmeta followed by every chained vbmeta, in the
/// order libavb loads them. `partition_image` maps a partition name to its
/// image file.
pub fn vbmeta_digest(vbmeta_image: &Path, partition_image: impl Fn(&str) -> Option<std::path::PathBuf>) -> Result<(usize, String), String> {
    let top = read(vbmeta_image)?;
    let top = vbmeta_struct(&top).ok_or("vbmeta.img: no vbmeta struct")?.to_vec();
    let mut all = top.clone();
    for name in chained_partitions(&top) {
        let Some(path) = partition_image(&name) else { continue };
        let data = read(&path)?;
        let chained = vbmeta_struct(&data).or_else(|| footer_vbmeta(&data)).ok_or(format!("{name}: no vbmeta"))?;
        all.extend_from_slice(chained);
    }
    let digest = sha256(&all);
    Ok((all.len(), digest.iter().map(|b| format!("{b:02x}")).collect()))
}

/// Partitions chained from `vbmeta_image`, for diagnostics.
pub fn vbmeta_chain(vbmeta_image: &Path) -> Result<Vec<String>, String> {
    let top = read(vbmeta_image)?;
    Ok(chained_partitions(vbmeta_struct(&top).ok_or("no vbmeta struct")?))
}

#[cfg(test)]
mod tests {
    #[test]
    fn cpio_archives_are_newc_with_a_trailer() {
        let archive = super::cpio_newc(&[("adb_debug.prop", b"ro.product.model=AVO-Droid\n")]);
        assert_eq!(&archive[..6], b"070701");
        assert_eq!(archive.len() % 4, 0);
        // Header (110 bytes), name with NUL padded to 4, then the data.
        let name_end = 110 + "adb_debug.prop".len() + 1;
        assert_eq!(&archive[110..name_end - 1], b"adb_debug.prop");
        let data_start = (name_end + 3) / 4 * 4;
        assert!(archive[data_start..].starts_with(b"ro.product.model=AVO-Droid\n"));
        assert!(archive.windows(10).any(|w| w == b"TRAILER!!!"));
        // File size field (7th) is the data length.
        assert_eq!(&archive[6 + 6 * 8..6 + 7 * 8], format!("{:08X}", 27).as_bytes());
    }

    use super::*;

    #[test]
    fn bootconfig_trailer_matches_the_kernel_format() {
        let mut initrd = vec![1, 2, 3];
        append_bootconfig(&mut initrd, "a=\"b\"\n");
        assert!(initrd.ends_with(b"#BOOTCONFIG\n"));
        let n = initrd.len();
        let size = u32::from_le_bytes(initrd[n - 20..n - 16].try_into().unwrap()) as usize;
        let checksum = u32::from_le_bytes(initrd[n - 16..n - 12].try_into().unwrap());
        let data = &initrd[n - 20 - size..n - 20];
        assert_eq!(&data[..6], b"a=\"b\"\n");
        assert_eq!(size % 4, 0);
        assert_eq!(checksum, data.iter().map(|&b| b as u32).sum::<u32>());
    }

    #[test]
    fn later_bootconfig_entries_win() {
        let text = bootconfig_text(&[("x".into(), "1".into()), ("y".into(), "2".into()), ("x".into(), "3".into())]);
        assert_eq!(text, "x=\"3\"\ny=\"2\"\n");
    }

    #[test]
    fn sha256_of_abc() {
        let digest = sha256(b"abc");
        assert_eq!(digest[..4], [0xba, 0x78, 0x16, 0xbf]);
    }
}
