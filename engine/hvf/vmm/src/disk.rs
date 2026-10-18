//! Disk backends for virtio-blk: a plain file, or a GPT disk composed from
//! one file per partition (like crosvm's composite disks), so Android sees
//! `/dev/block/by-name/<partition>` without copying images into one file.

use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;

pub const SECTOR: u64 = 512;

pub trait Disk: Send + Sync {
    fn size(&self) -> u64;
    fn read_only(&self) -> bool;
    fn read_at(&self, buf: &mut [u8], offset: u64) -> io::Result<()>;
    fn write_at(&self, buf: &[u8], offset: u64) -> io::Result<()>;
    fn flush(&self) -> io::Result<()>;
}

/// Reads `buf` from `file` at `offset`; past the end of the file reads zeros.
fn read_file(file: &File, buf: &mut [u8], offset: u64) -> io::Result<()> {
    let mut done = 0;
    while done < buf.len() {
        match file.read_at(&mut buf[done..], offset + done as u64)? {
            0 => {
                buf[done..].fill(0);
                break;
            }
            n => done += n,
        }
    }
    Ok(())
}

/// One partition of a composite disk.
pub struct PartitionSpec {
    pub name: String,
    pub path: std::path::PathBuf,
    pub read_only: bool,
}

struct Partition {
    name: String,
    file: File,
    start: u64,
    size: u64,
    read_only: bool,
}

pub struct CompositeDisk {
    head: Vec<u8>,
    tail: Vec<u8>,
    tail_start: u64,
    partitions: Vec<Partition>,
    size: u64,
}

const ALIGN: u64 = 1 << 20;
const ENTRIES: usize = 128;
const ENTRY_SIZE: usize = 128;
const ENTRIES_SECTORS: u64 = (ENTRIES * ENTRY_SIZE) as u64 / SECTOR;
/// Linux filesystem data, 0FC63DAF-8483-4772-8E79-3D69D8477DE4, in GPT byte order.
const LINUX_DATA: [u8; 16] = [
    0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4,
];

impl CompositeDisk {
    pub fn new(specs: &[PartitionSpec], disk_seed: &str) -> io::Result<CompositeDisk> {
        let mut partitions = Vec::new();
        let mut offset = ALIGN;
        for spec in specs {
            let file = std::fs::OpenOptions::new()
                .read(true)
                .write(!spec.read_only)
                .open(&spec.path)
                .map_err(|e| io::Error::new(e.kind(), format!("{}: {e}", spec.path.display())))?;
            let size = file.metadata()?.len().next_multiple_of(4096).max(4096);
            partitions.push(Partition { name: spec.name.clone(), file, start: offset, size, read_only: spec.read_only });
            offset = (offset + size).next_multiple_of(ALIGN);
        }
        let size = offset + ALIGN;
        let total_sectors = size / SECTOR;

        let mut entries = vec![0u8; ENTRIES * ENTRY_SIZE];
        for (i, p) in partitions.iter().enumerate() {
            let e = &mut entries[i * ENTRY_SIZE..(i + 1) * ENTRY_SIZE];
            e[0..16].copy_from_slice(&LINUX_DATA);
            e[16..32].copy_from_slice(&guid(&format!("{disk_seed}/{}", p.name)));
            e[32..40].copy_from_slice(&(p.start / SECTOR).to_le_bytes());
            e[40..48].copy_from_slice(&((p.start + p.size) / SECTOR - 1).to_le_bytes());
            for (j, unit) in p.name.encode_utf16().take(36).enumerate() {
                e[56 + j * 2..58 + j * 2].copy_from_slice(&unit.to_le_bytes());
            }
        }
        let entries_crc = crc32(&entries);
        let disk_guid = guid(disk_seed);
        let header = |my_lba: u64, other_lba: u64, entries_lba: u64| {
            let mut h = vec![0u8; SECTOR as usize];
            h[0..8].copy_from_slice(b"EFI PART");
            h[8..12].copy_from_slice(&0x0001_0000u32.to_le_bytes());
            h[12..16].copy_from_slice(&92u32.to_le_bytes());
            h[24..32].copy_from_slice(&my_lba.to_le_bytes());
            h[32..40].copy_from_slice(&other_lba.to_le_bytes());
            h[40..48].copy_from_slice(&(2 + ENTRIES_SECTORS).to_le_bytes());
            h[48..56].copy_from_slice(&(total_sectors - 2 - ENTRIES_SECTORS).to_le_bytes());
            h[56..72].copy_from_slice(&disk_guid);
            h[72..80].copy_from_slice(&entries_lba.to_le_bytes());
            h[80..84].copy_from_slice(&(ENTRIES as u32).to_le_bytes());
            h[84..88].copy_from_slice(&(ENTRY_SIZE as u32).to_le_bytes());
            h[88..92].copy_from_slice(&entries_crc.to_le_bytes());
            let crc = crc32(&h[..92]);
            h[16..20].copy_from_slice(&crc.to_le_bytes());
            h
        };

        // LBA 0: protective MBR; LBA 1: header; LBA 2..33: entries.
        let mut head = vec![0u8; SECTOR as usize];
        let mbr = &mut head[446..462];
        mbr[1..4].copy_from_slice(&[0x00, 0x02, 0x00]);
        mbr[4] = 0xee;
        mbr[5..8].copy_from_slice(&[0xff, 0xff, 0xff]);
        mbr[8..12].copy_from_slice(&1u32.to_le_bytes());
        mbr[12..16].copy_from_slice(&((total_sectors - 1).min(u32::MAX as u64) as u32).to_le_bytes());
        head[510] = 0x55;
        head[511] = 0xaa;
        head.extend(header(1, total_sectors - 1, 2));
        head.extend(&entries);

        // Backup entries, then the backup header in the last sector.
        let tail_start = size - (ENTRIES_SECTORS + 1) * SECTOR;
        let mut tail = entries.clone();
        tail.extend(header(total_sectors - 1, 1, total_sectors - 1 - ENTRIES_SECTORS));
        Ok(CompositeDisk { head, tail, tail_start, partitions, size })
    }

    pub fn layout(&self) -> Vec<(String, u64, u64)> {
        self.partitions.iter().map(|p| (p.name.clone(), p.start, p.size)).collect()
    }

    /// Calls `f` for each piece of [offset, offset + len): (piece offset in the
    /// request, its length, what backs it).
    fn segments(&self, offset: u64, len: usize, mut f: impl FnMut(usize, usize, Backing) -> io::Result<()>) -> io::Result<()> {
        let end = offset + len as u64;
        let mut at = offset;
        while at < end {
            let (piece_end, backing) = if at < self.head.len() as u64 {
                (self.head.len() as u64, Backing::Head)
            } else if at >= self.tail_start {
                (self.size, Backing::Tail)
            } else if let Some((i, p)) = self.partitions.iter().enumerate().find(|(_, p)| at >= p.start && at < p.start + p.size) {
                (p.start + p.size, Backing::Partition(i))
            } else {
                let next = self.partitions.iter().map(|p| p.start).filter(|&s| s > at).min().unwrap_or(self.tail_start);
                (next, Backing::Gap)
            };
            let piece_end = piece_end.min(end);
            f((at - offset) as usize, (piece_end - at) as usize, backing)?;
            at = piece_end;
        }
        Ok(())
    }
}

enum Backing {
    Head,
    Tail,
    Gap,
    Partition(usize),
}

impl Disk for CompositeDisk {
    fn size(&self) -> u64 {
        self.size
    }

    fn read_only(&self) -> bool {
        false
    }

    fn read_at(&self, buf: &mut [u8], offset: u64) -> io::Result<()> {
        self.segments(offset, buf.len(), |at, len, backing| {
            let out = &mut buf[at..at + len];
            let disk_offset = offset + at as u64;
            match backing {
                Backing::Head => out.copy_from_slice(&self.head[disk_offset as usize..disk_offset as usize + len]),
                Backing::Tail => {
                    let t = (disk_offset - self.tail_start) as usize;
                    out.copy_from_slice(&self.tail[t..t + len]);
                }
                Backing::Gap => out.fill(0),
                Backing::Partition(i) => {
                    let p = &self.partitions[i];
                    read_file(&p.file, out, disk_offset - p.start)?;
                }
            }
            Ok(())
        })
    }

    fn write_at(&self, buf: &[u8], offset: u64) -> io::Result<()> {
        self.segments(offset, buf.len(), |at, len, backing| match backing {
            Backing::Partition(i) => {
                let p = &self.partitions[i];
                if p.read_only {
                    return Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} is read-only", p.name)));
                }
                p.file.write_all_at(&buf[at..at + len], offset + at as u64 - p.start)
            }
            // Partition tables and gaps are not persisted.
            _ => Ok(()),
        })
    }

    fn flush(&self) -> io::Result<()> {
        for p in self.partitions.iter().filter(|p| !p.read_only) {
            p.file.sync_data()?;
        }
        Ok(())
    }
}

/// A stable, random-looking version 4 GUID derived from `seed`.
fn guid(seed: &str) -> [u8; 16] {
    let mut out = [0u8; 16];
    let mut state: u64 = 0xcbf2_9ce4_8422_2325;
    for (i, slot) in out.iter_mut().enumerate() {
        for byte in seed.bytes().chain([i as u8]) {
            state ^= byte as u64;
            state = state.wrapping_mul(0x0100_0000_01b3);
        }
        *slot = (state >> 32) as u8;
    }
    out[7] = (out[7] & 0x0f) | 0x40;
    out[8] = (out[8] & 0x3f) | 0x80;
    out
}

pub fn crc32(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in data {
        crc ^= byte as u32;
        for _ in 0..8 {
            crc = if crc & 1 != 0 { (crc >> 1) ^ 0xedb8_8320 } else { crc >> 1 };
        }
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc32_matches_the_standard_check_value() {
        assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    }

    #[test]
    fn composite_disk_has_a_valid_gpt_and_routes_partitions() {
        let dir = std::env::temp_dir().join(format!("avo-disk-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("a.img");
        let b = dir.join("b.img");
        std::fs::write(&a, vec![0xaa; 5000]).unwrap();
        std::fs::write(&b, vec![0xbb; 4096]).unwrap();
        let disk = CompositeDisk::new(
            &[
                PartitionSpec { name: "misc".into(), path: a.clone(), read_only: false },
                PartitionSpec { name: "super".into(), path: b.clone(), read_only: true },
            ],
            "test",
        )
        .unwrap();
        let mut sector = vec![0u8; 512];
        disk.read_at(&mut sector, 512).unwrap();
        assert_eq!(&sector[0..8], b"EFI PART");
        let crc = u32::from_le_bytes(sector[16..20].try_into().unwrap());
        sector[16..20].fill(0);
        assert_eq!(crc32(&sector[..92]), crc);

        let layout = disk.layout();
        assert_eq!(layout[0], ("misc".into(), 1 << 20, 8192));
        let mut data = vec![0u8; 8];
        disk.read_at(&mut data, layout[0].1 + 4996).unwrap();
        assert_eq!(data, [0xaa, 0xaa, 0xaa, 0xaa, 0, 0, 0, 0]);
        disk.write_at(&[1, 2], layout[0].1 + 10).unwrap();
        assert_eq!(&std::fs::read(&a).unwrap()[10..12], &[1, 2]);
        assert!(disk.write_at(&[1], layout[1].1).is_err());

        let mut last = vec![0u8; 512];
        disk.read_at(&mut last, disk.size() - 512).unwrap();
        assert_eq!(&last[0..8], b"EFI PART");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
