//! Android sparse images (libsparse) to raw files. "Don't care" chunks and
//! zero fills become holes, so an 8 GB super.img costs only its real data
//! on APFS.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::Path;

const MAGIC: u32 = 0xed26_ff3a;
const RAW: u16 = 0xcac1;
const FILL: u16 = 0xcac2;
const DONT_CARE: u16 = 0xcac3;
const CRC32: u16 = 0xcac4;

pub fn is_sparse(path: &Path) -> io::Result<bool> {
    let mut magic = [0u8; 4];
    let mut file = File::open(path)?;
    Ok(file.read_exact(&mut magic).is_ok() && u32::from_le_bytes(magic) == MAGIC)
}

/// Writes the expanded image of `source` to `destination` (replacing it).
pub fn unsparse(source: &Path, destination: &Path) -> io::Result<u64> {
    let mut input = io::BufReader::with_capacity(1 << 20, File::open(source)?);
    let mut header = [0u8; 28];
    input.read_exact(&mut header)?;
    let field = |at: usize| u32::from_le_bytes(header[at..at + 4].try_into().unwrap());
    let half = |at: usize| u16::from_le_bytes(header[at..at + 2].try_into().unwrap());
    if field(0) != MAGIC || half(4) != 1 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not a version 1 sparse image"));
    }
    let file_header_size = half(8) as usize;
    let chunk_header_size = half(10) as usize;
    let block_size = field(12) as u64;
    let total_blocks = field(16) as u64;
    let chunks = field(20);
    skip(&mut input, file_header_size.saturating_sub(28))?;

    let temporary = destination.with_extension("partial");
    let mut output = File::create(&temporary)?;
    let mut position = 0u64;
    let mut buffer = vec![0u8; 1 << 20];
    for _ in 0..chunks {
        let mut chunk = [0u8; 12];
        input.read_exact(&mut chunk)?;
        let kind = u16::from_le_bytes([chunk[0], chunk[1]]);
        let blocks = u32::from_le_bytes(chunk[4..8].try_into().unwrap()) as u64;
        let total = u32::from_le_bytes(chunk[8..12].try_into().unwrap()) as u64;
        skip(&mut input, chunk_header_size.saturating_sub(12))?;
        let bytes = blocks * block_size;
        match kind {
            RAW => {
                output.seek(SeekFrom::Start(position))?;
                let mut left = bytes;
                while left > 0 {
                    let n = left.min(buffer.len() as u64) as usize;
                    input.read_exact(&mut buffer[..n])?;
                    output.write_all(&buffer[..n])?;
                    left -= n as u64;
                }
            }
            FILL => {
                let mut pattern = [0u8; 4];
                input.read_exact(&mut pattern)?;
                if pattern != [0; 4] {
                    output.seek(SeekFrom::Start(position))?;
                    let block: Vec<u8> = pattern.iter().copied().cycle().take(block_size as usize).collect();
                    for _ in 0..blocks {
                        output.write_all(&block)?;
                    }
                }
            }
            DONT_CARE => {}
            CRC32 => skip(&mut input, 4)?,
            other => {
                return Err(io::Error::new(io::ErrorKind::InvalidData, format!("unknown sparse chunk {other:#x}")));
            }
        }
        let _ = total;
        position += bytes;
    }
    output.set_len(total_blocks * block_size)?;
    output.sync_all()?;
    std::fs::rename(&temporary, destination)?;
    Ok(total_blocks * block_size)
}

fn skip(input: &mut impl Read, n: usize) -> io::Result<()> {
    io::copy(&mut input.take(n as u64), &mut io::sink()).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_raw_fill_and_holes() {
        let dir = std::env::temp_dir().join(format!("avo-sparse-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut image = Vec::new();
        for v in [MAGIC] {
            image.extend(v.to_le_bytes());
        }
        image.extend(1u16.to_le_bytes());
        image.extend(0u16.to_le_bytes());
        image.extend(28u16.to_le_bytes());
        image.extend(12u16.to_le_bytes());
        image.extend(4096u32.to_le_bytes()); // block size
        image.extend(4u32.to_le_bytes()); // total blocks
        image.extend(3u32.to_le_bytes()); // chunks
        image.extend(0u32.to_le_bytes()); // checksum
        let chunk = |kind: u16, blocks: u32, total: u32| {
            let mut c = kind.to_le_bytes().to_vec();
            c.extend([0, 0]);
            c.extend(blocks.to_le_bytes());
            c.extend(total.to_le_bytes());
            c
        };
        image.extend(chunk(RAW, 1, 12 + 4096));
        image.extend(vec![7u8; 4096]);
        image.extend(chunk(DONT_CARE, 2, 12));
        image.extend(chunk(FILL, 1, 16));
        image.extend([1, 2, 3, 4]);
        let source = dir.join("in.img");
        let destination = dir.join("out.img");
        std::fs::write(&source, &image).unwrap();
        assert!(is_sparse(&source).unwrap());
        assert_eq!(unsparse(&source, &destination).unwrap(), 4 * 4096);
        let raw = std::fs::read(&destination).unwrap();
        assert_eq!(raw.len(), 4 * 4096);
        assert!(raw[..4096].iter().all(|&b| b == 7));
        assert!(raw[4096..3 * 4096].iter().all(|&b| b == 0));
        assert_eq!(&raw[3 * 4096..3 * 4096 + 8], &[1, 2, 3, 4, 1, 2, 3, 4]);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
