//! The engine's frame rings as the daemon reads them: one file per scanout
//! and layout ("generation") in the instance's `frames/` directory
//! (`frames/scanout-<index>-<generation>.frames`, a 4 KiB header and three
//! buffers; cuttlefish.rs:538 opens the writer at
//! `options.instance.join("frames")`). The Linux window shim displays one
//! Android app's surface off this reader — the file-read twin of the Mac's
//! mapped consumer (host/AvoKit/Sources/AvoDaemonCore/FrameBridge.swift),
//! reading plain files because the format already grants it: the ring is a
//! plain shared file on the writer side, "no engine change needed — the
//! ring is a plain mmap'd shared file already (verified)" (docs/linux-port.md,
//! phase-2 table). Phase 2's bar is exactly this reader (docs/linux-port.md:
//! "frames reach a reader through shared memory").
//!
//! The ring holds whole buffers, not a byte tail/head ring: a frame is one
//! buffer, `bytes per buffer` long and page-rounded (frames.rs:68), so
//! nothing straddles a wrap — what wraps is the index at header offset 40,
//! where the newest buffer is `counter % 3`. The writer fills only the
//! `(counter + 1) % 3` slot, never the newest, which readers may be
//! copying (frames.rs:94-105) — so "torn" copies are caught, not suffered:
//! the reader reads the counter, copies, and re-reads the counter; a rise
//! past one means the writer refilled the copied buffer and the copy is
//! dropped (frames.rs:97-101; FrameBridge.swift:259-263 the same rule).
//!
//! Header, little endian, the exact offsets the writer writes at creation
//! (engine/hvf/vmm/src/frames.rs:79-90); only offsets 40 and 48 change
//! after that:
//!
//! ```text
//!  0  magic "AVOF"          24  format (0 = BGRA, 1 = RGBA)
//!  4  version (1)           28  buffer count (3)
//!  8  generation            32  offset of buffer 0 (4096)
//! 12  width                 36  bytes per buffer (multiple of 4096)
//! 16  height                40  index of the newest complete buffer
//! 20  bytes per row         48  frames published (u64; 0 = none yet)
//! ```
//!
//! The daemon usually learns a ring from the engine's events — text lines
//! on the control socket (VMMEngine.swift:278-285 forwards each line):
//! `frames <scanout> <generation> <width> <height> <stride> <format>
//! <path>` before the first frame (the path may hold spaces),
//! `frame <scanout> <sequence>` per publication, `frames-off <scanout>` at
//! unplug (frames.rs:18-23, 305-323, 353, 340). The format carries no
//! timestamps — the counter is the ring's only per-frame metadata, the rest
//! is the header above. A ring appears only with its scanout's first frame,
//! never waiting for a reader (frames.rs:278-303); a failed layout is
//! retried a second later, not per frame (frames.rs:178-179, 284-286).

use std::cmp::Reverse;
use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{fence, Ordering};

/// Where the header ends and the buffers start — field 32's value the
/// writer writes (frames.rs:89).
pub const HEADER: u32 = 4096;

/// The byte order of a frame's pixels, from header field 24 — 0 is BGRA,
/// 1 is RGBA (frames.rs:87). Only two: the writer rotates alpha-first
/// layouts (ARGB becomes RGBA, ABGR becomes BGRA) before publishing
/// (frames.rs:150-169), and the consumer keys the surfaces off the same
/// code (FrameBridge.swift:195-196).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Format {
    Bgra,
    Rgba,
}

/// One committed frame's copy, as the daemon needs it to show a surface.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Frame {
    /// The layout's identity — the same generation the engine's `frames`
    /// event announces (frames.rs:290) and the file name carries.
    pub generation: u32,
    pub width: u32,
    pub height: u32,
    /// Bytes per row as the header carries them (field 20). The writer
    /// stores rows packed at exactly this pitch — `width * 4` bytes per row,
    /// no resource padding (frames.rs:67, 119-121) — and the Mac consumer
    /// reads them row-wise by the same field (FrameBridge.swift:251-257).
    pub row_bytes: u32,
    pub format: Format,
    /// The counter's value when the copy finished: the frame the ring had
    /// committed. When the writer stood still during the copy this is
    /// exactly the frame the bytes hold; when it published once during the
    /// copy the bytes hold one of two committed frames (which one is not
    /// observable), refreshed by the next publication — the skew the Swift
    /// consumer tolerates the same way by delivering the event's sequence
    /// (FrameBridge.swift:275).
    pub sequence: u64,
    /// The image, `height` rows of `row_bytes`, packed.
    pub pixels: Vec<u8>,
}

/// The header's static fields — written once at creation (frames.rs:79-90),
/// read once here. Only the newest index (40) and the counter (48) change
/// after that; the Mac consumer caches the same fields the same way
/// (FrameBridge.swift:191-192).
#[derive(Clone, Copy, Debug)]
pub struct Header {
    pub generation: u32,
    pub width: u32,
    pub height: u32,
    pub row_bytes: u32,
    /// The ring's own buffer count, which the newest index must stay under
    /// (the writer writes 3, frames.rs:88).
    pub buffers: u32,
    pub buffer_offset: u32,
    pub buffer_bytes: u32,
    pub format: Format,
}

/// One ring file, open for reading without a mapping: plain `read_at`s go
/// through the same page-cache pages the writer writes into (the writer
/// maps the file itself MAP_SHARED, frames.rs:72). Anywhere the format
/// needs ordering the reader does what the mapped consumer does with its
/// acquiring fences (FrameBridge.swift:231-262): the writer publishes
/// buffer bytes, then the index, then the counter, each behind a release
/// fence (frames.rs:102, 133-137), and these reads stay in that order.
#[derive(Debug)]
pub struct Ring {
    path: PathBuf,
    file: File,
    header: Header,
}

impl Ring {
    /// Opens one ring file, its header read and checked once. The Mac
    /// consumer opens O_RDONLY and stats before mapping
    /// (FrameBridge.swift:175-189); the same checks reject anything that is
    /// not the engine's ring.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Ring> {
        let path = path.as_ref().to_path_buf();
        let file = File::open(&path)?;
        let file_len = file.metadata()?.len();
        let mut bytes = [0u8; 56];
        file.read_exact_at(&mut bytes, 0)?;
        Ok(Ring { path, file, header: Header::parse(&bytes, file_len)? })
    }

    /// The header's static fields.
    pub fn header(&self) -> &Header {
        &self.header
    }

    /// The ring's path — what the engine's `frames` event names (it may
    /// contain spaces; the event's own words stop at the seventh,
    /// FrameBridge.swift:152-156).
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Frames published so far (field 48): 0 until the first ("0 = none
    /// yet", frames.rs:15). The Mac's frame-rate sampling reads exactly
    /// this counter per layout, published to a window or not
    /// (FrameBridge.swift:224-235).
    pub fn published(&self) -> io::Result<u64> {
        let mut bytes = [0u8; 8];
        self.file.read_exact_at(&mut bytes, 48)?;
        let counter = u64::from_le_bytes(bytes);
        // The counter is the last thing the writer publishes (frames.rs:133-137),
        // behind a release fence; the consumer reads it then fences acquires
        // (FrameBridge.swift:231-234) — mirrored, to order against the
        // index and buffer reads below.
        fence(Ordering::Acquire);
        Ok(counter)
    }

    /// The newest committed frame, whatever came before: `None` while the
    /// ring has published nothing (the counter's 0, frames.rs:15).
    pub fn frame(&self) -> io::Result<Option<Frame>> {
        self.frame_after(0)
    }

    /// The next frame past what the caller holds, `None` when the counter
    /// has not moved past `seen`. This is the skip the Swift consumer makes
    /// per frame event — `published <= sequence else return nil`: "Behind
    /// newer frames (the event pump fell behind): their events follow, and
    /// the newest one is copied then" (FrameBridge.swift:243-246) — as a
    /// pull; `frame()` (seen 0) is the copy now, which is what the same
    /// consumer does when a hidden window shows again and takes the newest
    /// frame at once (FrameBridge.swift:132-145).
    pub fn frame_after(&self, seen: u64) -> io::Result<Option<Frame>> {
        let pre = self.published()?;
        if pre <= seen {
            return Ok(None);
        }
        let Some(index) = self.newest_index()? else { return Ok(None) };
        let pixels = self.copy_buffer(index)?;
        let post = self.published()?;
        let Some(sequence) = committed(pre, post) else { return Ok(None) };
        Ok(Some(Frame {
            generation: self.header.generation,
            width: self.header.width,
            height: self.header.height,
            row_bytes: self.header.row_bytes,
            format: self.header.format,
            sequence,
            pixels,
        }))
    }

    /// Whether the engine no longer advertises this ring's name: a layout
    /// change or an unplug deletes the file ("Readers keep their mapping;
    /// the name goes away with the layout", frames.rs:145-146; announced as
    /// `frames-off <index>`), and the next boot deletes every `*.frames`
    /// file as stale (frames.rs:242-246). The open reader is not disturbed
    /// by any of that — the last frame stays readable from the removed
    /// file, frozen where the writer stopped.
    pub fn gone(&self) -> bool {
        std::fs::metadata(&self.path).is_err()
    }

    /// The newest buffer's index (field 40), read after the counter: the
    /// writer puts the index in place before the counter that publishes it
    /// (frames.rs:133-137), so everything the counter shows has an index
    /// behind it. Anything past the header's buffer count is skipped like
    /// the consumer's `latest < 3` guard (FrameBridge.swift:247-248) — a
    /// header torn beyond the format's own order, which the counter check
    /// would not have admitted past four publications anyway.
    fn newest_index(&self) -> io::Result<Option<u32>> {
        let mut bytes = [0u8; 4];
        self.file.read_exact_at(&mut bytes, 40)?;
        let index = u32::from_le_bytes(bytes);
        fence(Ordering::Acquire);
        if index >= self.header.buffers {
            return Ok(None);
        }
        Ok(Some(index))
    }

    /// One whole buffer at `index` — one read at its offset, rows
    /// un-pitched into the image. A frame never straddles buffers (each is
    /// a page-rounded whole: frames.rs:68), so even the file's last byte is
    /// the last row's last byte.
    fn copy_buffer(&self, index: u32) -> io::Result<Vec<u8>> {
        let mut slot = vec![0u8; self.header.buffer_bytes as usize];
        let at = self.header.buffer_offset as u64 + index as u64 * self.header.buffer_bytes as u64;
        self.file.read_exact_at(&mut slot, at)?;
        fence(Ordering::Acquire);
        let row = self.header.row_bytes as usize;
        let mut pixels = Vec::with_capacity(row * self.header.height as usize);
        for y in 0..self.header.height as usize {
            pixels.extend_from_slice(&slot[y * row..y * row + row]);
        }
        Ok(pixels)
    }
}

/// The copy rule the two counter reads decide, one place. A rise of one or
/// none keeps the copy (the refilled slot is not the copied one); more
/// drops it without inspecting the bytes — "the daemon reads the counter
/// before and after copying the newest buffer and drops the copy if it rose
/// by more than one: this buffer was the newest two frames ago"
/// (frames.rs:97-101), the consumer's side being its guard
/// `published <= published + 1` (FrameBridge.swift:262-263).
fn committed(pre: u64, post: u64) -> Option<u64> {
    (post <= pre.saturating_add(1)).then_some(post)
}

/// The rings a frames directory advertises, one per scanout, sorted by
/// scanout index — for a daemon that boots after the engine, where no
/// `frames` event has named the paths yet. The writer makes a new
/// generation's file before the old layout is dropped (frames.rs:279-291),
/// so two generations of one scanout can exist for a moment and the newest
/// per index is the live one; names that cannot be opened are skipped
/// rather than failing the scan, since the writer deletes a replaced
/// layout at any moment (frames.rs:145-146).
pub fn scan(directory: &Path) -> io::Result<Vec<Ring>> {
    let mut found: Vec<(u32, u32, PathBuf)> = Vec::new();
    for entry in std::fs::read_dir(directory)?.flatten() {
        if let Some((index, generation)) = ring_name(&entry.path()) {
            found.push((index, generation, entry.path()));
        }
    }
    found.sort_by_key(|&(index, generation, _)| (index, Reverse(generation)));
    found.dedup_by_key(|entry| entry.0);
    let mut rings = Vec::new();
    for (_, _, path) in found {
        if let Ok(ring) = Ring::open(&path) {
            rings.push(ring);
        }
    }
    Ok(rings)
}

/// (scanout index, generation) in the name the writer gives its files —
/// `scanout-<index>-<generation>.frames` (frames.rs:288). Anything else is
/// not a ring of this format.
fn ring_name(path: &Path) -> Option<(u32, u32)> {
    let name = path.file_name()?.to_str()?;
    let name = name.strip_prefix("scanout-")?;
    let name = name.strip_suffix(".frames")?;
    let (index, generation) = name.split_once('-')?;
    Some((index.parse().ok()?, generation.parse().ok()?))
}

impl Header {
    /// Reads the static half of the header exactly as the writer put it
    /// (frames.rs:80-90), taking the file's length along because the
    /// writer truncates to the exact extent the fields describe before any
    /// byte is written (frames.rs:70-71).
    fn parse(bytes: &[u8; 56], file_len: u64) -> io::Result<Header> {
        const MAGIC: [u8; 4] = *b"AVOF";
        if &bytes[0..4] != &MAGIC {
            return Err(invalid("the file is not an engine frame ring: its magic is not AVOF"));
        }
        // The writer puts 1 in field 4 and never rewritten versions are a
        // thing: a ring whose header says otherwise is not its format.
        let version = u32_at(bytes, 4);
        if version != 1 {
            return Err(invalid(format!("the ring's header version is {version}, not 1")));
        }
        let format = match u32_at(bytes, 24) {
            0 => Format::Bgra,
            1 => Format::Rgba,
            other => return Err(invalid(format!("the ring's pixel format code is {other}, not 0 or 1"))),
        };
        let width = u32_at(bytes, 12);
        let height = u32_at(bytes, 16);
        let row_bytes = u32_at(bytes, 20);
        let buffers = u32_at(bytes, 28);
        let buffer_offset = u32_at(bytes, 32) as u64;
        let buffer_bytes = u32_at(bytes, 36) as u64;
        // The engine's scanout rects are never empty (zero-sized creates
        // and scanouts are refused: virtio/gpu.rs:360, 445), so zeros here
        // are a corrupt file's, not a real ring's.
        if width == 0 || height == 0 || row_bytes == 0 || buffers == 0 {
            return Err(invalid("the ring's dimensions or buffer count are zero"));
        }
        if row_bytes as u64 * height as u64 > buffer_bytes
            || buffer_offset < HEADER as u64
            || buffer_offset + buffers as u64 * buffer_bytes > file_len
        {
            return Err(invalid("the ring's buffers do not fit the file as its header claims"));
        }
        Ok(Header {
            generation: u32_at(bytes, 8),
            width,
            height,
            row_bytes,
            buffers,
            buffer_offset: u32_at(bytes, 32),
            buffer_bytes: u32_at(bytes, 36),
            format,
        })
    }
}

/// A protocol-or-layout offence, the shape vsock.rs returns its refusals in.
fn invalid(text: impl AsRef<str>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, text.as_ref())
}

fn u32_at(bytes: &[u8; 56], at: usize) -> u32 {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The writer in miniature: Surface::create's file layout and
    /// publish_next's publication order (engine/hvf/vmm/src/frames.rs:66-92,
    /// 129-139), byte for byte, so the reader is checked against the
    /// engine's real shape rather than a sample that happens to work.
    struct Fixture {
        path: PathBuf,
        file: File,
        sequence: u64,
        width: u32,
        height: u32,
    }

    /// A distinct temp path without coordination — the engine pid plus a
    /// per-call counter, the way vsock's tests name their sockets.
    fn unique(name: &str) -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        std::env::temp_dir().join(format!(
            "avod-frames-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ))
    }

    impl Fixture {
        /// One new ring file: `format` is the header's code (0 BGRA, 1 RGBA).
        fn new(name: &str, width: u32, height: u32, format: u32) -> Fixture {
            let path = unique(name);
            let file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
            let mut fixture = Fixture { path, file, sequence: 0, width, height };
            // The writer sets the file's length to the full extent before a
            // byte of header is written (frames.rs:70-71): without it the
            // slots the header names do not exist on disk.
            fixture.file.set_len(HEADER as u64 + 3 * fixture.buffer_bytes() as u64).unwrap();
            fixture.write_header(1, format);
            fixture
        }

        /// The buffer size the writer rounds to: per-row bytes times rows,
        /// next multiple of 4096 (frames.rs:68).
        fn buffer_bytes(&self) -> u32 {
            (self.width as usize * 4 * self.height as usize).next_multiple_of(4096) as u32
        }

        /// The header the writer writes at creation, field for field
        /// (frames.rs:80-90).
        fn write_header(&mut self, generation: u32, format: u32) {
            let mut header = vec![0u8; HEADER as usize];
            header[0..4].copy_from_slice(b"AVOF");
            let mut put = |at: usize, value: u32| header[at..at + 4].copy_from_slice(&value.to_le_bytes());
            put(4, 1);
            put(8, generation);
            put(12, self.width);
            put(16, self.height);
            put(20, self.width * 4);
            put(24, format);
            put(28, 3);
            put(32, HEADER);
            put(36, self.buffer_bytes());
            self.file.write_all_at(&header, 0).unwrap();
        }

        /// Publishes one frame the way publish() and publish_next() do:
        /// rows packed into the `(counter + 1) % 3` slot, then the index,
        /// then the counter, release fences between (frames.rs:115-139).
        fn publish(&mut self, pixels: &[u8]) -> u64 {
            let row = (self.width * 4) as usize;
            let next = (self.sequence + 1) % 3;
            let at = HEADER as u64 + next * self.buffer_bytes() as u64;
            for (y, source) in pixels.chunks_exact(row).enumerate() {
                self.file.write_all_at(source, at + y as u64 * row as u64).unwrap();
            }
            fence(Ordering::Release);
            self.file.write_all_at(&(next as u32).to_le_bytes(), 40).unwrap();
            fence(Ordering::Release);
            self.sequence += 1;
            self.file.write_all_at(&self.sequence.to_le_bytes(), 48).unwrap();
            self.sequence
        }
    }

    /// A ring file made under an existing directory, named as the writer
    /// names them (frames.rs:288) — for the scan tests.
    fn fixture_in(directory: &Path, index: u32, generation: u32, width: u32, height: u32) -> Fixture {
        let path = directory.join(format!("scanout-{index}-{generation}.frames"));
        let file = std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(true).open(&path).unwrap();
        let mut fixture = Fixture { path, file, sequence: 0, width, height };
        fixture.file.set_len(HEADER as u64 + 3 * fixture.buffer_bytes() as u64).unwrap();
        fixture.write_header(generation, 0);
        fixture
    }

    /// A frame's worth of distinct bytes.
    fn pixels_of(width: u32, height: u32, seed: u8) -> Vec<u8> {
        (0..width as usize * 4 * height as usize).map(|i| seed.wrapping_add(i as u8)).collect()
    }

    #[test]
    fn no_frames_yet_reads_nothing_and_the_first_frame_reads_whole() {
        let mut fixture = Fixture::new("first", 5, 3, 0);
        // The counter's 0 is "none yet" (frames.rs:15): a reader that opens
        // before the first publication sees a ring asleep, the same
        // `sequence > 0` check the consumer makes on a freshly shown
        // window (FrameBridge.swift:144).
        let ring = Ring::open(&fixture.path).unwrap();
        assert_eq!(ring.published().unwrap(), 0);
        assert_eq!(ring.frame().unwrap(), None);

        let bytes = pixels_of(5, 3, 0x40);
        fixture.publish(&bytes);
        let frame = ring.frame().unwrap().unwrap();
        assert_eq!(frame.sequence, 1);
        assert_eq!(frame.pixels, bytes);
        assert_eq!((frame.width, frame.height, frame.row_bytes), (5, 3, 20));
        assert_eq!((frame.format, frame.generation), (Format::Bgra, 1));

        // The file is what the writer truncated it to: a page-round header
        // and one page-round slot per buffer (frames.rs:68-71).
        let slot = fixture.buffer_bytes();
        assert_eq!(std::fs::metadata(&fixture.path).unwrap().len(), (HEADER + 3 * slot) as u64);
    }

    #[test]
    fn the_slot_size_is_the_headers_rounding_not_the_frames() {
        // A row of 1025 pixels is 4100 bytes; a buffer is the next multiple
        // of 4096 (frames.rs:68). The reader takes slot offsets only from
        // the header and never assumes the frame sits tight.
        let mut fixture = Fixture::new("wide", 1025, 1, 0);
        let ring = Ring::open(&fixture.path).unwrap();
        assert_eq!(ring.header().buffer_bytes, 8192);
        let bytes = pixels_of(1025, 1, 0x7F);
        fixture.publish(&bytes);
        assert_eq!(ring.frame().unwrap().unwrap().pixels, bytes);
        assert_eq!(std::fs::metadata(&fixture.path).unwrap().len(), HEADER as u64 + 3 * 8192);
    }

    #[test]
    fn the_index_wraps_and_the_newest_frame_still_reads() {
        // The imagined "two-read wrap" — a frame straddling the ring —
        // does not exist in this format: every frame is exactly one buffer,
        // a page-rounded whole (frames.rs:68), so nothing ever straddles.
        // What wraps is field 40's index. Four publications run the index
        // 1, 2, 0, 1 — frame 4 rewrites frame 1's slot, and the copy across
        // that boundary stays one whole read holding exactly what was
        // published there.
        let mut fixture = Fixture::new("wrap", 5, 3, 0);
        let ring = Ring::open(&fixture.path).unwrap();
        let frames: Vec<Vec<u8>> = (1..=4).map(|n| pixels_of(5, 3, n)).collect();
        for frame in &frames {
            fixture.publish(frame);
        }
        let frame = ring.frame().unwrap().unwrap();
        assert_eq!(frame.sequence, 4);
        assert_eq!(frame.pixels, frames[3]);
        // The reader carries no per-frame state: the same slot reads again
        // exactly, for as long as the writer adds nothing.
        assert_eq!(ring.frame().unwrap().unwrap(), frame);
        assert_eq!(ring.published().unwrap(), 4);
    }

    #[test]
    fn a_stopped_writer_freezes_and_the_dropped_name_is_seen() {
        let mut fixture = Fixture::new("stopped", 5, 3, 0);
        let ring = Ring::open(&fixture.path).unwrap();
        let first = pixels_of(5, 3, 0x11);
        fixture.publish(&first);
        let second = pixels_of(5, 3, 0x22);
        fixture.publish(&second);
        let frame = ring.frame().unwrap().unwrap();
        assert_eq!(frame.sequence, 2);

        // The writer stopping is invisible in the bytes: the counter
        // stands where the last publication put it and the newest frame
        // stays readable, exactly as the last time. Nothing the format
        // grants says more — the events, and then the name, are the
        // liveness signals (frames.rs:18-23, 340).
        assert_eq!(ring.published().unwrap(), 2);
        assert_eq!(ring.frame().unwrap().unwrap(), frame);

        // The engine's unplug removes the file (Surface::drop, frames.rs:145-146)
        // but leaves open readers alone ("Readers keep their mapping"): the
        // frozen file stays readable and `gone()` says the name has gone.
        std::fs::remove_file(&fixture.path).unwrap();
        assert!(ring.gone());
        assert_eq!(ring.frame().unwrap().unwrap(), frame);
        // And a fresh open finds nothing: this layout is over, the way the
        // next boot's stale-file sweep (frames.rs:242-246) or a `frames-off`
        // event says.
        assert_eq!(Ring::open(&fixture.path).unwrap_err().kind(), io::ErrorKind::NotFound);
    }

    #[test]
    fn a_copy_the_counter_outran_is_dropped_like_the_consumer_drops_it() {
        // The rule table first: rise 0 and 1 keep (the copied slot is not
        // the one the writer refills within one publication), 2 and past
        // drop without a look at the bytes — frames.rs:97-101, the
        // consumer's guard `published <= published + 1`
        // (FrameBridge.swift:262-263).
        assert_eq!(committed(7, 7), Some(7));
        assert_eq!(committed(7, 8), Some(8));
        assert_eq!(committed(7, 9), None);

        // The file-level shape of the race, driven deterministically by
        // composing the same reads frame() composes: counter first, then
        // the engine publishes twice, then index, copy, counter again.
        let mut fixture = Fixture::new("outran", 5, 3, 0);
        let ring = Ring::open(&fixture.path).unwrap();
        let frames: Vec<Vec<u8>> = (1..=3).map(|n| pixels_of(5, 3, n)).collect();
        fixture.publish(&frames[0]);
        let pre = ring.published().unwrap();
        fixture.publish(&frames[1]);
        fixture.publish(&frames[2]);
        let index = ring.newest_index().unwrap().unwrap();
        assert_eq!(index, 0, "3 % 3: frame 3 sits in the first slot");
        // The slot the late index names is whole — frame 3, not the
        // recycling writer's two steps later — but "whole" is not
        // observable across the reader's own window: the counter moved
        // 1 → 3, past the one-rise allowance, and the rule drops the copy
        // rather than answer. Conservative on purpose; the next pull
        // re-reads with a quiet writer.
        assert_eq!(ring.copy_buffer(index).unwrap(), frames[2]);
        assert_eq!(committed(pre, ring.published().unwrap()), None);
        assert_eq!(ring.frame_after(2).unwrap().unwrap().sequence, 3);
    }

    #[test]
    fn a_pull_behind_its_last_held_frame_skips() {
        // The consumer's per-event skip as a pull (FrameBridge.swift:243-246):
        // what the caller already holds returns nothing, and the next
        // publication answers with the newest not the missed middle ones —
        // "their events follow, and the newest one is copied then".
        let mut fixture = Fixture::new("skip", 5, 3, 0);
        let ring = Ring::open(&fixture.path).unwrap();
        let held = fixture.publish(&pixels_of(5, 3, 0x31));
        assert_eq!(ring.frame_after(held).unwrap(), None);
        let second = pixels_of(5, 3, 0x32);
        fixture.publish(&second);
        let frame = ring.frame_after(held).unwrap().unwrap();
        assert_eq!(frame.sequence, 2);
        assert_eq!(frame.pixels, second);
        // And the unconditional copy — seen 0 — is the "copies the newest
        // frame at once" call of a re-shown window
        // (FrameBridge.swift:132-145).
        assert_eq!(ring.frame().unwrap().unwrap().sequence, 2);
    }

    #[test]
    fn the_format_code_is_honored_as_the_bytes_come() {
        // Code 1 is RGBA (frames.rs:87) and the bytes pass through as they
        // are: the engine never stores a pixel alpha-first — such layouts
        // are rotated into BGRA/RGBA before publishing (frames.rs:150-169),
        // so the reader has no rotation of its own to make.
        let mut fixture = Fixture::new("rgba", 2, 1, 1);
        let ring = Ring::open(&fixture.path).unwrap();
        assert_eq!(ring.header().format, Format::Rgba);
        let bytes = pixels_of(2, 1, 0x5A);
        fixture.publish(&bytes);
        let frame = ring.frame().unwrap().unwrap();
        assert_eq!((frame.format, frame.pixels), (Format::Rgba, bytes));
    }

    #[test]
    fn the_scan_reports_the_newest_generation_of_each_scanout() {
        // Two generations of one scanout sit on disk for a moment — the new
        // file is made before the old layout is dropped (frames.rs:279-291)
        // — so the newest per index is the live one, and the rings come
        // back in scanout order however the generations ran.
        let directory = unique("scan");
        std::fs::create_dir(&directory).unwrap();
        let old = fixture_in(&directory, 0, 1, 5, 3);
        let new = fixture_in(&directory, 0, 2, 8, 3);
        let other = fixture_in(&directory, 1, 1, 5, 3);
        let rings = scan(&directory).unwrap();
        assert_eq!(
            rings.iter().map(|r| (r.header().generation, r.header().width)).collect::<Vec<_>>(),
            [(2, 8), (1, 5)]
        );
        assert_eq!(rings[0].path(), new.path);
        assert_eq!(rings[1].path(), other.path);
        assert!(rings.iter().all(|r| r.path() != old.path));

        // A short file under a ring-formed name is the normal cost of
        // racing a writer that deletes replaced layouts (frames.rs:145-146):
        // skipped, not a failed scan.
        let short = directory.join("scanout-2-1.frames");
        std::fs::write(&short, [0u8; 30]).unwrap();
        assert_eq!(Ring::open(&short).unwrap_err().kind(), io::ErrorKind::UnexpectedEof);
        assert_eq!(scan(&directory).unwrap().len(), 2);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}
