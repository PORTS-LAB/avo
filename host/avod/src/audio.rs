//! The daemon's audio rings: the engine's tap of what Android plays, read
//! side, and the capture ring the daemon fills for the guest's microphone.
//!
//! Playback is the engine's file: every period Android's sound streams have
//! played lands in a ring of shared memory so a window host can record an
//! app window with the sound that played while its frames showed then
//! (engine/hvf/vmm/src/virtio/sound/tap.rs). One ring per engine process,
//! `<instance>/audio/playback.ring` (the engine makes the `audio` folder and
//! opens the ring there, cuttlefish.rs), announced over the control socket
//! with the sticky event `audio playback <epoch> <path>` (tap.rs
//! `Ring::event`). A new engine process removes the old file and makes a new
//! one under the same name with a new epoch; a reader keeps its handle to
//! the old ring and takes a new one when the control channel says the epoch
//! moved (tap.rs; the Mac's reader does the same with its mapping,
//! host/AvoKit CaptureAudio.swift `AudioTapReader`).
//!
//! The ring reads back through plain file reads, with no mapping of its
//! own: the engine writes through a shared mapping (tap.rs mmaps
//! MAP_SHARED), so the pages the reads touch are the pages the writes land
//! in, and each read's kernel copy stands where the mapped writer's release
//! fences were. The stamp fields and the publish order below are tap.rs's.
//!
//! The capture ring is the daemon's side of the same machinery: the Linux
//! stand-in for what the engine does on its own on the Mac, where Core
//! Audio's input callback feeds the stream's `captured` bytes directly
//! (sound.rs `recorded`; the Linux engine's own microphone thread does it
//! from ALSA, sound.rs `open_microphone`). No engine reader reads this file
//! yet — the daemon fills `<instance>/audio/capture.ring` so one can stand
//! in: bytes in stream order, as the capture path takes them, whole periods
//! of a stream's own stride, silence filled past the recorded end and at
//! most four periods held with the oldest shed (sound.rs's capture path:
//! `deliver_capture` drains whole periods and pads with zeros, the source
//! arms cap the hold at `period_bytes * 4` and drain the excess from the
//! front). The slots carry the tap's layout, so the same reader machinery
//! serves both rings; what the capture path needs from a slot is its bytes
//! in sequence order, everything else decoration.

use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};

/// The tap's magic (tap.rs `MAGIC`).
const MAGIC: [u8; 4] = *b"AVOA";
/// A 4 KiB header, then the slots (tap.rs `HEADER`).
const HEADER: usize = 4096;
/// A slot's stamp field runs to the PCM, at 32 (tap.rs `SLOT_HEADER`).
const SLOT_HEADER: usize = 32;
/// The ring version the engine writes (tap.rs `put(4, 1)`).
const VERSION: u32 = 1;
/// Interleaved signed 16-bit little endian, the tap's only format (tap.rs
/// `FORMAT_S16LE`).
const FORMAT_S16LE: u16 = 1;
/// Bit 0 of a slot's flags: the stream run's first audio (tap.rs
/// `FLAG_RUN_START`).
const FLAG_RUN_START: u32 = 1;

/// CLOCK_MONOTONIC's id on Linux, the tap's own non-Mac stamping clock:
/// the engine stamps in CLOCK_MONOTONIC nanoseconds and publishes a 1:1
/// timebase (tap.rs `host_clock_and_base`'s non-Mac arm; the call is
/// pause.rs's `host_ticks`, nanoseconds).
const CLOCK_MONOTONIC: i32 = 1;

/// `struct timespec`, as pause.rs's clock_gettime call takes it.
#[repr(C)]
struct Timespec {
    sec: i64,
    nsec: i64,
}

unsafe extern "C" {
    fn clock_gettime(clock_id: i32, time: *mut Timespec) -> i32;
}

/// The host clock now, CLOCK_MONOTONIC nanoseconds (pause.rs's same call,
/// same assert when the clock is gone).
fn monotonic_ns() -> u64 {
    let mut now = Timespec { sec: 0, nsec: 0 };
    let ok = unsafe { clock_gettime(CLOCK_MONOTONIC, &mut now) } == 0;
    assert!(ok, "clock_gettime(CLOCK_MONOTONIC)");
    (now.sec as u64).wrapping_mul(1_000_000_000).wrapping_add(now.nsec as u64)
}

fn invalid(text: impl AsRef<str>) -> std::io::Error {
    std::io::Error::new(ErrorKind::InvalidData, text.as_ref())
}

/// One published slot's audio — the fields the readers use, one bounded
/// chunk of at most the ring's PCM bytes per slot (tap.rs's slot table; the
/// Mac's `AudioBlock` carries the same fields, CaptureAudio.swift).
#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    /// Host time of the chunk's first frame, in the ring's own clock. The
    /// engine's non-Mac stamps are CLOCK_MONOTONIC nanoseconds, 1:1 in the
    /// header's published (1, 1) timebase (tap.rs).
    pub host_time: u64,
    pub rate: u32,
    pub channels: u16,
    /// S16 frames, interleaved.
    pub frames: u32,
    /// The stream's first audio: its time starts it anew (tap.rs
    /// FLAG_RUN_START; the Mac's `runStart`).
    pub run_start: bool,
    /// S16LE interleaved, `frames * channels * 2` bytes as the slot holds
    /// them (the Mac's reader unpacks them into Int16s; the byte form is
    /// the same frames).
    pub samples: Vec<u8>,
}

/// The engine's playback ring, read side. `PlaybackRing::open` checks the
/// ring the way the header says it must be laid out (tap.rs `create`), and
/// every `read` returns what the engine added since the last one, oldest
/// first.
///
/// The copy can never tear. The engine publishes a slot as a seqlock (tap.rs
/// `publish`): the slot's sequence zeroed first, then its fields and PCM,
/// then its own sequence, and only then the header's newest sequence — three
/// release fences in the mapped writer, and a reader copies between them is
/// caught by the second look at the sequence. So a slot the header names
/// newest is complete, and a reader whose walk falls while the engine comes
/// round to a slot again drops that copy rather than a mixed one (the Mac's
/// reader does the same two checks, CaptureAudio.swift: "A torn copy … is
/// dropped").
#[derive(Debug)]
pub struct PlaybackRing {
    file: File,
    /// Header fields 8 and 12, checked at open and never theirs again: a
    /// replaced ring is a new file, and this handle keeps its inode.
    slots: usize,
    slot_size: usize,
    /// The epoch at header offset 24, which the opener's caller matched
    /// against the one `audio playback` announced.
    epoch: u64,
    /// The next sequence to read; a fresh reader starts past what the header
    /// already named, reading only what is added from now on.
    next: u64,
}

impl PlaybackRing {
    /// Opens the ring at `path`, with `epoch` the one the daemon's control
    /// channel heard announced as `audio playback <epoch> <path>`. The
    /// epoch binds at open the way the Mac's reader binds its announced
    /// location (CaptureAudio.swift `init` checks `header.epoch ==
    /// location.epoch`): an engine that crashed leaves the last ring on the
    /// disk until the next one replaces it (tap.rs `Ring::create` removes
    /// the file first), and only the announcement's epoch says this is the
    /// live one.
    pub fn open(path: impl AsRef<Path>, epoch: u64) -> std::io::Result<PlaybackRing> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        let mut header = [0u8; HEADER];
        file.read_exact_at(&mut header, 0)?;
        let word = |at: usize| u32::from_le_bytes(header[at..at + 4].try_into().unwrap());
        if header[0..4] != MAGIC {
            return Err(invalid("the file at the path is not the engine's audio ring: its magic is not the tap's \"AVOA\""));
        }
        if word(4) != VERSION {
            return Err(invalid(format!("the ring's version is {}, and this reader reads {}", word(4), VERSION)));
        }
        let slots = word(8) as usize;
        let slot_size = word(12) as usize;
        if slots == 0 {
            return Err(invalid("the ring's header counts no slots"));
        }
        if slot_size <= SLOT_HEADER {
            return Err(invalid("the ring's slots are smaller than their stamp"));
        }
        // The PCM bytes per slot are the slot minus its stamp (header field
        // 16); the Mac checks the same shape.
        if word(16) != slot_size as u32 - SLOT_HEADER as u32 {
            return Err(invalid("the ring's PCM bytes per slot do not follow from its slot size"));
        }
        // u128: an absurd header must fail the fit, never the arithmetic.
        let need = (HEADER as u128) + slots as u128 * slot_size as u128;
        if need > len as u128 {
            return Err(invalid("the ring file is shorter than its header describes"));
        }
        let announced = u64::from_le_bytes(header[24..32].try_into().unwrap());
        if announced != epoch {
            return Err(invalid(format!("the ring's epoch is {announced}, not the announcement's {epoch}")));
        }
        let next = u64::from_le_bytes(header[32..40].try_into().unwrap()) + 1;
        Ok(PlaybackRing { file, slots, slot_size, epoch: announced, next })
    }

    /// The epoch the ring carries — the one `audio playback` announced.
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// The blocks added since the last call, oldest first; `lost` when some
    /// were written over before they could be read — either the reader fell
    /// behind by the whole ring, or a copy tore and was dropped. The same
    /// answer the Mac's `read()` gives (CaptureAudio.swift).
    pub fn read(&mut self) -> std::io::Result<(Vec<Block>, bool)> {
        // As far as the header's newest sequence (offset 32), reread per
        // call: the writer moves it without telling anyone.
        let mut header = [0u8; 40];
        self.file.read_exact_at(&mut header, 0)?;
        let newest = u64::from_le_bytes(header[32..40].try_into().unwrap());
        if newest < self.next {
            return Ok((Vec::new(), false));
        }
        let mut lost = false;
        let slots = self.slots as u64;
        // Older ones are gone: the ring holds `slots` (the Mac's reader
        // makes the same skip).
        if newest - self.next >= slots {
            self.next = newest - slots + 1;
            lost = true;
        }
        let mut blocks = Vec::new();
        while self.next <= newest {
            match self.slot(self.next)? {
                Some(block) => blocks.push(block),
                None => lost = true,
            }
            self.next += 1;
        }
        Ok((blocks, lost))
    }

    /// Copies out the slot of `sequence` (at
    /// `HEADER + (sequence % slots) * slot_size`, tap.rs). None when the
    /// engine was rewriting it meanwhile (a torn copy), or the slot does
    /// not decode.
    fn slot(&self, sequence: u64) -> std::io::Result<Option<Block>> {
        let at = (HEADER as u64) + (sequence % self.slots as u64) * self.slot_size as u64;
        let mut slot = vec![0u8; self.slot_size];
        self.file.read_exact_at(&mut slot, at)?;
        let long = |from: usize| u64::from_le_bytes(slot[from..from + 8].try_into().unwrap());
        let word = |from: usize| u32::from_le_bytes(slot[from..from + 4].try_into().unwrap());
        // One buffer, two looks at the sequence: now, from the copy, and
        // again from the file after the copy — what the mapped reader's two
        // stamps with their acquire fence are (CaptureAudio.swift slot()).
        if long(0) != sequence {
            return Ok(None);
        }
        let host_time = long(8);
        let rate = word(16);
        let channels = u16::from_le_bytes(slot[20..22].try_into().unwrap());
        let format = u16::from_le_bytes(slot[22..24].try_into().unwrap());
        let frames = word(24);
        let flags = word(28);
        // The gates the Mac's reader applies to what a stamp alone did not
        // prove: the tap's format, a rate, one or two channels, and frames
        // that fit the slot (CaptureAudio.swift).
        if format != FORMAT_S16LE || rate == 0 || !(1..=2).contains(&channels) {
            return Ok(None);
        }
        let bytes = frames as u64 * channels as u64 * 2;
        if bytes > (self.slot_size - SLOT_HEADER) as u64 {
            return Ok(None);
        }
        let mut live = [0u8; 8];
        self.file.read_exact_at(&mut live, at)?;
        if live != sequence.to_le_bytes() {
            return Ok(None);
        }
        Ok(Some(Block {
            host_time,
            rate,
            channels,
            frames,
            run_start: (flags & FLAG_RUN_START) != 0,
            samples: slot[SLOT_HEADER..SLOT_HEADER + bytes as usize].to_vec(),
        }))
    }
}

/// The daemon's capture ring: the microphone side's half of the rings. The
/// daemon creates `audio/capture.ring` under the instance and writes what
/// the Mac's Core Audio callback writes into the engine's stream `captured`
/// (sound.rs `recorded`; the Linux engine's microphone thread does that from
/// ALSA, sound.rs `open_microphone` — the ring is the stand-in for a source
/// outside the engine process, should the engine's capture path read one).
///
/// The layout is the tap's (the same reader serves both rings), and the
/// publish order is the tap's `publish` byte for byte, save that the writes
/// are file writes: each `write_at` returning is where the mapped writer's
/// release fences stood.
#[derive(Debug)]
pub struct CaptureRing {
    file: File,
    path: PathBuf,
    slots: usize,
    slot_size: usize,
    /// This ring's own epoch (header 24): a fresh CLOCK_MONOTONIC tick, at
    /// least 1 as the tap's is (tap.rs `epoch.max(1)`).
    epoch: u64,
    /// The last sequence published.
    sequence: u64,
    /// The stream run (sound.rs names capture runs by its run id,
    /// `Audio::id`; the daemon's rendition by what its control channel's
    /// `sound capture on|off` tell it) whose audio was last written.
    run: u64,
}

impl CaptureRing {
    /// Creates the ring file at `path`, in place of an older one. The same
    /// construction the engine's tap does (tap.rs `Ring::create`): a new
    /// file, never the old one rewritten, so a reader holding the old inode
    /// never sees the file shrink under it. The header leaves its magic to
    /// last — a reader never takes a half-made header (tap.rs).
    pub fn create(path: &Path, slots: usize, slot_size: usize) -> std::io::Result<CaptureRing> {
        if slots == 0 || slot_size <= SLOT_HEADER {
            return Err(invalid("a ring needs slots of more than a stamp's bytes"));
        }
        let len = (HEADER as u64) + slots as u64 * slot_size as u64;
        let _ = std::fs::remove_file(path);
        let file = OpenOptions::new().read(true).write(true).create_new(true).open(path)?;
        file.set_len(len)?;
        let mut header = [0u8; HEADER];
        let mut put = |at: usize, value: u32| header[at..at + 4].copy_from_slice(&value.to_le_bytes());
        put(4, VERSION);
        put(8, slots as u32);
        put(12, slot_size as u32);
        // The PCM bytes per slot: the slot minus its stamp (tap.rs `put(16, …)`).
        put(16, slot_size as u32 - SLOT_HEADER as u32);
        // The daemon's stamps are CLOCK_MONOTONIC nanoseconds, published
        // 1:1 (the tap's non-Mac arm, tap.rs `host_clock_and_base`).
        put(40, 1);
        put(44, 1);
        // The epoch: a fresh CLOCK_MONOTONIC tick, at least 1, new for
        // every ring (tap.rs's `epoch.max(1)`): 0 is the "nothing yet" of
        // the header's newest field beside it.
        let epoch = monotonic_ns().max(1);
        header[24..32].copy_from_slice(&epoch.to_le_bytes());
        // The newest complete slot (header 32) stands at 0: none yet, what
        // the file's zeros already say.
        let _ = file.write_all_at(&header, 0)?;
        // The magic last (tap.rs): its write is what makes the header whole
        // to a reader.
        let _ = file.write_all_at(&MAGIC, 0)?;
        Ok(CaptureRing {
            file,
            path: path.to_path_buf(),
            slots,
            slot_size,
            epoch,
            sequence: 0,
            run: 0,
        })
    }

    /// The ring's own epoch, for whatever announces it.
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Adds just-recorded audio of stream run `run` (S16, interleaved), in
    /// the shape the engine's capture path takes in: the tap's
    /// `Ring::write`, with a slot per chunk of the slot's capacity, the
    /// run's first audio flagged (tap.rs FLAG_RUN_START) and the flag
    /// cleared for the rest. The slot's stamp is the CLOCK_MONOTONIC
    /// nanosecond the bytes entered — one per call, since what was recorded
    /// recorded: the capture path carries no playhead to backdate from (the
    /// tap's end-stamp math, tap.rs `ended_at`, is playback's). An empty
    /// write still moves the run marker, as it does in the engine's tap.
    pub fn write(&mut self, run: u64, rate: u32, channels: u8, pcm: &[u8]) -> std::io::Result<()> {
        let frame_bytes = channels as usize * 2;
        if rate == 0 || frame_bytes == 0 {
            return Ok(());
        }
        let frames = pcm.len() / frame_bytes;
        let per_slot = (self.slot_size - SLOT_HEADER) / frame_bytes;
        let now = monotonic_ns();
        let mut first_flag = if run != self.run { FLAG_RUN_START } else { 0 };
        self.run = run;
        let mut done = 0;
        while done < frames {
            let count = per_slot.min(frames - done);
            let bytes = &pcm[done * frame_bytes..(done + count) * frame_bytes];
            self.publish(now, rate, channels, count as u32, first_flag, bytes)?;
            first_flag = 0;
            done += count;
        }
        Ok(())
    }

    /// The tap's `publish`, as file writes: the slot's sequence zeroed,
    /// its stamp fields, its PCM, its sequence, and only then the header's
    /// newest — the order a reader's second look at a sequence stands on
    /// (tap.rs `publish`; the write boundaries are the file's stand-in for
    /// the mapped writer's release fences).
    fn publish(&mut self, start: u64, rate: u32, channels: u8, frames: u32, flags: u32, pcm: &[u8]) -> std::io::Result<()> {
        let sequence = self.sequence + 1;
        let at = (HEADER as u64) + (sequence % self.slots as u64) * self.slot_size as u64;
        // The tap's order (tap.rs `publish`): the slot's sequence zeroed,
        // its fields and PCM with them, its sequence (the release), and
        // only then the header's newest. The stamp is the slot's own first
        // 32 bytes — sequence at 0 within it, and the header field the
        // header's first bytes at 32 of the file (the mmap's `header` runs
        // the first HEADER bytes, tap.rs).
        self.file.write_all_at(&[0u8; 8], at)?;
        let mut stamp = [0u8; SLOT_HEADER];
        stamp[8..16].copy_from_slice(&start.to_le_bytes());
        stamp[16..20].copy_from_slice(&rate.to_le_bytes());
        stamp[20..22].copy_from_slice(&(channels as u16).to_le_bytes());
        stamp[22..24].copy_from_slice(&FORMAT_S16LE.to_le_bytes());
        stamp[24..28].copy_from_slice(&frames.to_le_bytes());
        stamp[28..32].copy_from_slice(&flags.to_le_bytes());
        self.file.write_all_at(&stamp, at)?;
        self.file.write_all_at(pcm, at + SLOT_HEADER as u64)?;
        let mark = sequence.to_le_bytes();
        self.file.write_all_at(&mark, at)?;
        self.file.write_all_at(&mark, 32)?;
        self.sequence = sequence;
        Ok(())
    }
}

impl Drop for CaptureRing {
    fn drop(&mut self) {
        // The file goes with the ring (tap.rs's Drop and its test).
        let _ = std::fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A per-test folder next to nothing else's.
    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("avod-audio-{}-{name}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The ring's words, out of a byte vector, little endian.
    fn u32_at(data: &[u8], at: usize) -> u32 {
        u32::from_le_bytes(data[at..at + 4].try_into().unwrap())
    }
    fn u64_at(data: &[u8], at: usize) -> u64 {
        u64::from_le_bytes(data[at..at + 8].try_into().unwrap())
    }

    /// A playback ring laid out byte for byte as the engine's writer does
    /// (engine/hvf/vmm/src/virtio/sound/tap.rs): the header's fields first
    /// with the magic last (`create`), and in `publish` a slot's sequence
    /// zeroed, its fields and PCM, its sequence, then the header's newest.
    /// Sizes are the tap's own test rig's: 4 slots of 128 bytes, 96 PCM
    /// bytes apiece, 24 stereo frames to a slot.
    struct Written {
        path: PathBuf,
        bytes: Vec<u8>,
        slots: usize,
        slot_size: usize,
        newest: u64,
    }

    impl Written {
        /// `epoch` stands where the engine writes a fresh host tick (any
        /// nonzero tick will do: readers bind to it, they do not count it).
        fn create(path: PathBuf, slots: usize, slot_size: usize, epoch: u64) -> Written {
            let mut bytes = vec![0u8; HEADER + slots * slot_size];
            // tap.rs `put(4, 1)`, and fields 8/12/16; epoch at 24; the
            // CLOCK_MONOTONIC 1:1 base at 40/44.
            let mut put = |at: usize, value: u32| bytes[at..at + 4].copy_from_slice(&value.to_le_bytes());
            put(4, 1);
            put(8, slots as u32);
            put(12, slot_size as u32);
            put(16, slot_size as u32 - SLOT_HEADER as u32);
            put(40, 1);
            put(44, 1);
            bytes[24..32].copy_from_slice(&epoch.to_le_bytes());
            // The magic last: a reader never takes a half-made header (tap.rs).
            bytes[0..4].copy_from_slice(&MAGIC);
            std::fs::write(&path, &bytes).unwrap();
            Written { path, bytes, slots, slot_size, newest: 0 }
        }

        /// tap.rs `publish`, with the header's newest carried too. The
        /// stamp fields land at fixed offsets so the reader's reading of
        /// them says what the writer wrote, field by field.
        fn publish(&mut self, sequence: u64, start: u64, rate: u32, channels: u16, format: u16, frames: u32, flags: u32, pcm: &[u8]) {
            let at = HEADER + (sequence % self.slots as u64) as usize * self.slot_size;
            let slot = &mut self.bytes[at..at + self.slot_size];
            slot[0..8].copy_from_slice(&0u64.to_le_bytes());
            slot[8..16].copy_from_slice(&start.to_le_bytes());
            slot[16..20].copy_from_slice(&rate.to_le_bytes());
            slot[20..22].copy_from_slice(&channels.to_le_bytes());
            slot[22..24].copy_from_slice(&format.to_le_bytes());
            slot[24..28].copy_from_slice(&frames.to_le_bytes());
            slot[28..32].copy_from_slice(&flags.to_le_bytes());
            slot[SLOT_HEADER..SLOT_HEADER + pcm.len()].copy_from_slice(pcm);
            slot[0..8].copy_from_slice(&sequence.to_le_bytes());
            self.bytes[32..40].copy_from_slice(&sequence.to_le_bytes());
            self.newest = sequence;
            std::fs::write(&self.path, &self.bytes).unwrap();
        }

        /// The host ticks `frames` take at `rate`, the tap's backdating
        /// math with its 1:1 base (tap.rs `write` and `ticks`): a chunk
        /// starting `done` frames in stamps `end − ticks(frames − done)`.
        fn ticks(frames: usize, rate: u32) -> u64 {
            frames as u64 * 1_000_000_000 / rate as u64
        }

        fn file(&self) -> Vec<u8> {
            std::fs::read(&self.path).unwrap()
        }
    }

    /// A reader takes one poll's worth of the engine's published slots,
    /// reading the stamp fields back as the writer wrote them, starting
    /// from nothing (a fresh reader starts at the header's newest + 1: what
    /// is added from now on).
    #[test]
    fn a_normal_chunk_read_takes_the_stamps_and_the_samples() {
        let dir = temp("chunk");
        let path = dir.join("playback.ring");
        // 48 frames of stereo at 48 kHz that end together at 10 s: the tap
        // splits it in two slots of 24 frames, the first stamping 10 s less
        // its whole length, the second 10 s less half of it.
        let frames = 48;
        let rate = 48_000;
        let end = Written::ticks(48_000 * 10, rate);
        let pcm: Vec<u8> = (0..frames * 4).map(|i| (i * 7 % 256) as u8).collect();
        let mut wrote = Written::create(path.clone(), 4, 128, 42);
        let first = &pcm[..96];
        let second = &pcm[96..];

        // A wrong epoch is not the announced ring: the Mac's reader refuses
        // its location's mismatch the same way at open.
        let error = PlaybackRing::open(&path, 43).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);

        let mut ring = PlaybackRing::open(&path, 42).unwrap();
        assert_eq!(ring.epoch(), 42);
        assert_eq!(ring.read().unwrap(), (Vec::new(), false), "nothing yet");

        let start = end - Written::ticks(frames, rate);
        wrote.publish(1, start, rate, 2, FORMAT_S16LE, 24, FLAG_RUN_START, first);
        let later = end - Written::ticks(frames - 24, rate);
        wrote.publish(2, later, rate, 2, FORMAT_S16LE, 24, 0, second);

        let (blocks, lost) = ring.read().unwrap();
        assert!(!lost);
        assert_eq!(blocks.len(), 2);
        // The stamps read back at the tap's offsets (slot fields 8..32),
        // first frame's host time at 8, rate/channels/format/frames/flags
        // where the writer set them.
        assert_eq!((blocks[0].host_time, blocks[0].rate, blocks[0].channels), (start, rate, 2));
        assert_eq!((blocks[0].frames, blocks[0].run_start), (24, true), "the run's first audio");
        assert_eq!(blocks[0].samples, first);
        assert_eq!((blocks[1].host_time, blocks[1].frames, blocks[1].run_start), (later, 24, false));
        assert_eq!(blocks[1].samples, second);
        // And the cursor stands past the newest: another poll with the
        // writer at rest is empty.
        assert_eq!(ring.read().unwrap(), (Vec::new(), false));
        drop(ring);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A reader falling behind by the whole ring cannot have the slots the
    /// engine wrote over: it skips to the newest and says so, twice over —
    /// first read wraps, second catches up from where the first left it.
    #[test]
    fn a_reader_behind_a_whole_ring_skips_to_the_newest() {
        let dir = temp("wrap");
        let path = dir.join("playback.ring");
        let mut wrote = Written::create(path.clone(), 2, 128, 7);
        let mut ring = PlaybackRing::open(&path, 7).unwrap();
        assert_eq!(ring.read().unwrap(), (Vec::new(), false));

        let start = 1_000;
        wrote.publish(1, start, 48_000, 2, FORMAT_S16LE, 24, FLAG_RUN_START, &[1; 96]);
        wrote.publish(2, start + 500, 48_000, 2, FORMAT_S16LE, 24, 0, &[2; 96]);
        let (blocks, lost) = ring.read().unwrap();
        assert!(!lost);
        assert_eq!(blocks.len(), 2);

        // Three more while next stood at 3: sequences 3 to 5 went over
        // slots 1 and 2 and round again — the reader is a whole ring (and
        // a slot) behind, so 3 is gone forever and it takes 4 on.
        wrote.publish(3, start + 1_000, 48_000, 2, FORMAT_S16LE, 24, 0, &[3; 96]);
        wrote.publish(4, start + 1_500, 48_000, 2, FORMAT_S16LE, 24, 0, &[4; 96]);
        wrote.publish(5, start + 2_000, 48_000, 2, FORMAT_S16LE, 24, 0, &[5; 96]);
        let (blocks, lost) = ring.read().unwrap();
        assert!(lost, "older ones were written over before they were read");
        // 4 lands at index 0 (4 % 2), 5 at index 1: what the wrap-around
        // discipline says (tap.rs: slot of sequence n at 4096 + (n % count)
        // * bytes per slot).
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0].samples, vec![4; 96]);
        assert_eq!(blocks[0].host_time, start + 1_500);
        assert_eq!(blocks[1].samples, vec![5; 96]);

        // The catch-up read after it: from where the first left the cursor.
        wrote.publish(6, start + 2_500, 48_000, 2, FORMAT_S16LE, 24, 0, &[6; 96]);
        let (blocks, lost) = ring.read().unwrap();
        assert!(!lost, "no longer behind a whole ring");
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].samples, vec![6; 96]);
        drop(ring);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A writer that stopped leaves the reader empty polls and its place:
    /// the header's newest sequence standing still is the ring's whole
    /// observable of a stopped writer — the format carries no alive mark
    /// (tap.rs's slot and header tables say what there is, and this is it).
    /// The daemon's on/off knowledge of a stream comes from its control
    /// channel instead (`sound playback on|off`, a sticky event the engine's
    /// control socket keeps; the Mac's daemon parses the same lines). A
    /// reader joining after the writer stopped sees the same: nothing, and
    /// the past is not replayed — a fresh reader starts past the header's
    /// newest, as the Mac's does.
    #[test]
    fn a_stopped_writer_leaves_the_read_empty_and_the_place_standing() {
        let dir = temp("stopped");
        let path = dir.join("playback.ring");
        let mut wrote = Written::create(path.clone(), 4, 128, 9);
        wrote.publish(1, 100, 48_000, 2, FORMAT_S16LE, 24, FLAG_RUN_START, &[1; 96]);
        wrote.publish(2, 600, 48_000, 2, FORMAT_S16LE, 24, 0, &[2; 96]);
        wrote.publish(3, 1_100, 48_000, 2, FORMAT_S16LE, 24, 0, &[3; 96]);

        let mut ring = PlaybackRing::open(&path, 9).unwrap();
        assert_eq!(ring.read().unwrap(), (Vec::new(), false), "the past is not for a joiner");
        assert_eq!(ring.read().unwrap(), (Vec::new(), false), "and the writer stopped");
        // The header's newest stands where the writer left it: nothing
        // moved, nothing will, and the reader's place is where it was.
        assert_eq!(u64_at(&wrote.file(), 32), 3);
        drop(ring);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A published stamp is not a guarantee of the rest: a slot stamped
    /// like a good one but shaped wrong comes out as lost, and the polls
    /// carry the good blocks (the Mac's reader answers nil for such and
    /// marks lost; the tap decodes S16LE only, with a rate and channels
    /// that fit).
    #[test]
    fn a_slot_that_decodes_wrong_comes_out_lost() {
        let dir = temp("mangled");
        let path = dir.join("playback.ring");
        let mut wrote = Written::create(path.clone(), 4, 128, 11);
        // The reader was there polling before the bad slots went up: a
        // reader joining after would start past the newest and see none of
        // it (the fresh reader's place, above).
        let mut ring = PlaybackRing::open(&path, 11).unwrap();
        let start = 500;
        wrote.publish(1, start, 48_000, 2, FORMAT_S16LE, 24, FLAG_RUN_START, &[1; 96]);
        // A stamp the engine never writes (format 7): the copy drops.
        wrote.publish(2, start + 500, 48_000, 2, 7, 24, 0, &[2; 96]);
        // Frames that claim more PCM than a slot's 96 bytes hold.
        wrote.publish(3, start + 1_000, 48_000, 2, FORMAT_S16LE, 40, 0, &[3; 96]);
        let (blocks, lost) = ring.read().unwrap();
        assert!(lost);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].samples, vec![1; 96]);
        drop(ring);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// The capture writer lays its ring out as the tap's slots, byte for
    /// byte: the header's fields with the magic last, slots published in
    /// the tap's order, the cursor (the header's newest) advancing past
    /// every one, a new run flagged once. 1000 stereo frames at 48 kHz
    /// split into 42 slots of 24 frames, the last one 16 — the same split
    /// the engine's tap makes of the same audio (tap.rs's own test
    /// publishes exactly this count).
    #[test]
    fn the_capture_writer_publishes_whole_slots_and_flags_a_new_run() {
        let dir = temp("capture");
        let dir = dir.join("audio");
        std::fs::create_dir_all(&dir).unwrap(); // the engine's tap does this in its open() (tap.rs)
        let path = dir.join("capture.ring");
        let mut ring = CaptureRing::create(&path, 4, 128).unwrap();

        let wrote = std::fs::read(&path).unwrap();
        assert_eq!(&wrote[0..4], &MAGIC);
        assert_eq!(&wrote[4..8], &1u32.to_le_bytes(), "the tap's version (put(4, 1))");
        assert_eq!(&wrote[8..12], &4u32.to_le_bytes(), "slots");
        assert_eq!(&wrote[12..16], &128u32.to_le_bytes(), "bytes per slot");
        assert_eq!(&wrote[16..20], &96u32.to_le_bytes(), "PCM bytes per slot, the slot minus its stamp");
        assert_eq!(u64_at(&wrote, 24), ring.epoch(), "the epoch announced with a ring");
        assert_eq!(u64_at(&wrote, 32), 0, "nothing yet");
        assert_eq!((u32_at(&wrote, 40), u32_at(&wrote, 44)), (1, 1), "the CLOCK_MONOTONIC 1:1 base");
        assert_eq!(&wrote[HEADER..HEADER + 32], &[0u8; 32][..], "the slots stand at zero until published");

        // 1000 frames of stereo at 48 kHz: 42 slots of 24 frames, the last
        // 16, going round the ring of 4 twice and a bit.
        let first_pcm: Vec<u8> = (0..4000).map(|i| (i * 5 % 256) as u8).collect();
        ring.write(7, 48_000, 2, &first_pcm).unwrap();
        let wrote = std::fs::read(&path).unwrap();
        assert_eq!(u64_at(&wrote, 32), 42, "the header's newest names the last slot");
        // The newest slot at index 2: 16 frames, the audio's tail.
        let slot = &wrote[HEADER + 2 * 128..][..128];
        assert_eq!(u64_at(slot, 0), 42);
        assert_eq!(u32_at(slot, 16), 48_000);
        assert_eq!(u16::from_le_bytes(slot[20..22].try_into().unwrap()), 2, "channels");
        assert_eq!(u16::from_le_bytes(slot[22..24].try_into().unwrap()), FORMAT_S16LE);
        assert_eq!(u32_at(slot, 24), 16);
        assert_eq!(u32_at(slot, 28), 0, "not the run's first audio");
        assert_eq!(&slot[32..96], &first_pcm[4000 - 64..]);
        // The one before it, a whole slot of 24 frames, stamped with the
        // same moment the bytes entered (one write, one stamp: the capture
        // path has no playhead to backdate from the way the tap's
        // `ended_at` does for playback).
        let previous = &wrote[HEADER + 1 * 128..][..128];
        assert_eq!(u64_at(previous, 0), 41);
        assert_eq!(u32_at(previous, 24), 24);
        assert_eq!(u64_at(previous, 8), u64_at(slot, 8));
        // An overwritten slot carries only its newest writer's sequence:
        // sequence 1's slot (index 1) holds 41 now.
        assert_eq!(u64_at(&wrote[HEADER + 1 * 128..][..128], 0), 41);

        // A new run is flagged in its first slot only.
        ring.write(8, 44_100, 1, &[1, 0, 2, 0]).unwrap();
        let wrote = std::fs::read(&path).unwrap();
        let slot = &wrote[HEADER + 3 * 128..][..128];
        assert_eq!(u64_at(slot, 0), 43);
        assert_eq!(u32_at(slot, 16), 44_100);
        assert_eq!(u16::from_le_bytes(slot[20..22].try_into().unwrap()), 1, "mono");
        assert_eq!((u32_at(slot, 24), u32_at(slot, 28)), (2, FLAG_RUN_START));
        assert!(u64_at(slot, 8) >= u64_at(previous, 8), "stamps move forward");

        drop(ring);
        assert!(!path.exists(), "the file goes with the ring");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A new ring replaces the file but not a reader of the old one: the
    /// daemon's capture ring is replaced the way the engine replaces its
    /// playback ring (tap.rs `Ring::create` removes before it creates; its
    /// test does the same two-ring dance), and a reader holding an open
    /// handle reads its own inode on — only the control channel's next
    /// announcement moves it, bound by the epoch the old ring carries.
    #[test]
    fn a_replaced_capture_ring_leaves_an_old_reader_its_own_file() {
        let dir = temp("replaced");
        let dir = dir.join("audio");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("capture.ring");

        let mut old = CaptureRing::create(&path, 2, 64).unwrap();
        old.write(1, 48_000, 2, &[1, 0, 2, 0]).unwrap();
        let old_epoch = old.epoch();
        let mut reader = PlaybackRing::open(&path, old_epoch).unwrap();
        assert_eq!(reader.read().unwrap(), (Vec::new(), false), "a fresh reader starts at the newest + 1");

        // The engine's replacement: a new ring under the same path, a new
        // epoch — the old file unlinked and gone from the path, not gone
        // from its handles.
        let fresh = CaptureRing::create(&path, 2, 64).unwrap();
        assert_ne!(fresh.epoch(), old_epoch, "a new ring, a new epoch");
        let written = std::fs::read(&path).unwrap();
        assert_ne!(u64_at(&written, 24), old_epoch, "the path's file carries the new epoch");
        assert_eq!(u64_at(&written, 32), 0, "and it stands empty");

        // The reader does not follow the path: it holds the old inode, and
        // the old ring keeps writing into it.
        old.write(1, 48_000, 2, &[2, 0, 3, 0]).unwrap();
        let (blocks, lost) = reader.read().unwrap();
        assert!(!lost);
        assert_eq!(blocks.len(), 1, "the old ring's next slot, not the path's new file");
        assert_eq!(blocks[0].samples, vec![2, 0, 3, 0]);

        // And the path does not answer the old epoch any more: the new
        // announcement binds where the reader opens next.
        let error = PlaybackRing::open(&path, old_epoch).unwrap_err();
        assert_eq!(error.kind(), ErrorKind::InvalidData);

        drop(reader);
        drop(old);
        drop(fresh);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
