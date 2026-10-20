//! The host's PCM on Linux: ALSA's `default` device, which on most systems
//! is a PipeWire or PulseAudio server's ALSA emulation, and on a bare one
//! the sound card itself. Loaded from `libasound.so.2` on demand (the GPU
//! libraries load the same way), so a machine without it — or without audio
//! at all — keeps sound.rs's null backend instead: the sound is dropped and
//! the clock keeps the guest's time.
//!
//! The device's own clock writes one period when its tick says so; ALSA's
//! ring buffers what has been written, and the server carries it off at its
//! own pace. A write is accepted only while the ring has a period of room;
//! otherwise the period is dropped, the same thing the Mac's queue does
//! past MAX_QUEUED. The playhead's distance comes back with every accepted
//! period (`accept`), which the tap stamps as the host time the sound will
//! have played at. For capture, a plain period-by-period read into the
//! device's ring; silence when there is no source.
//!
//! Thread discipline: the handle belongs to the stream whose thread opened
//! it — playback's writes (`accept`), capture's reads (`record`), and the
//! freeze/thaw both happen on that stream's clock thread (which sees the
//! pause transitions first); the drop comes from whichever thread holds the
//! last reference after the stream has ended, and nothing runs by then. The
//! calls therefore never race each other, which is what the shared `Arc` in
//! sound.rs's state relies on.

use std::ffi::{c_char, c_int, c_long, c_void};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// snd_pcm_t.
type Pcm = *mut c_void;
/// snd_pcm_sframes_t; snd_pcm_uframes_t is its unsigned sibling.
type Frames = c_long;

/// snd_pcm_stream_t.
const STREAM_PLAYBACK: c_int = 0;
const STREAM_CAPTURE: c_int = 1;
/// snd_pcm_access_t.
const RW_INTERLEAVED: u32 = 3;
/// snd_pcm_format_t.
const S16_LE: u32 = 2;

const EPIPE: c_int = libc::EPIPE; // 32 on Linux; 11 is EAGAIN there
const ESTRPIPE: c_int = libc::ESTRPIPE;

struct Symbols {
    open: unsafe extern "C" fn(*mut Pcm, *const c_char, c_int, c_int) -> c_int,
    close: unsafe extern "C" fn(Pcm) -> c_int,
    hw_params_malloc: unsafe extern "C" fn(*mut *mut c_void) -> c_int,
    hw_params_free: unsafe extern "C" fn(*mut c_void),
    hw_params_any: unsafe extern "C" fn(Pcm, *mut c_void) -> c_int,
    hw_params_set_access: unsafe extern "C" fn(Pcm, *mut c_void, u32) -> c_int,
    hw_params_set_format: unsafe extern "C" fn(Pcm, *mut c_void, u32) -> c_int,
    hw_params_set_channels: unsafe extern "C" fn(Pcm, *mut c_void, u32) -> c_int,
    hw_params_set_rate_near: unsafe extern "C" fn(Pcm, *mut c_void, *mut u32, *mut i32) -> c_int,
    hw_params_set_period_size_near: unsafe extern "C" fn(Pcm, *mut c_void, *mut u64, *mut i32) -> c_int,
    hw_params_set_buffer_size_near: unsafe extern "C" fn(Pcm, *mut c_void, *mut u64, *mut i32) -> c_int,
    hw_params: unsafe extern "C" fn(Pcm, *mut c_void) -> c_int,
    sw_params_malloc: unsafe extern "C" fn(*mut *mut c_void) -> c_int,
    sw_params_free: unsafe extern "C" fn(*mut c_void),
    sw_params_current: unsafe extern "C" fn(Pcm, *mut c_void) -> c_int,
    sw_params_set_start_threshold: unsafe extern "C" fn(Pcm, *mut c_void, u64) -> c_int,
    sw_params_set_avail_min: unsafe extern "C" fn(Pcm, *mut c_void, u64) -> c_int,
    sw_params: unsafe extern "C" fn(Pcm, *mut c_void) -> c_int,
    prepare: unsafe extern "C" fn(Pcm) -> c_int,
    drop_pcm: unsafe extern "C" fn(Pcm) -> c_int,
    pause: unsafe extern "C" fn(Pcm, c_int) -> c_int,
    start: unsafe extern "C" fn(Pcm) -> c_int,
    recover: unsafe extern "C" fn(Pcm, c_int, c_int) -> c_int,
    avail_update: unsafe extern "C" fn(Pcm) -> Frames,
    delay: unsafe extern "C" fn(Pcm, *mut Frames) -> c_int,
    writei: unsafe extern "C" fn(Pcm, *const c_void, u64) -> Frames,
    readi: unsafe extern "C" fn(Pcm, *mut c_void, u64) -> Frames,
    wait: unsafe extern "C" fn(Pcm, c_int) -> c_int,
}

static LIBRARY: OnceLock<Result<Symbols, String>> = OnceLock::new();

/// Loads the symbols. None on any machine without libasound, which sound.rs
/// treats as "no audio here" and runs its clock alone.
fn library() -> Option<&'static Symbols> {
    let loaded = LIBRARY.get_or_init(|| {
        // The runtime name first; a dev-system's unversioned name behind it.
        let mut error = String::new();
        for name in [c"libasound.so.2", c"libasound.so"] {
            let handle = unsafe { libc::dlopen(name.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
            if handle.is_null() {
                let raw = unsafe { libc::dlerror() };
                error = if raw.is_null() {
                    format!("{} cannot load", name.to_string_lossy())
                } else {
                    unsafe { std::ffi::CStr::from_ptr(raw) }.to_string_lossy().into_owned()
                };
                continue;
            }
            macro_rules! symbol {
                ($symbol:literal) => {{
                    let pointer = unsafe { libc::dlsym(handle, concat!($symbol, "\0").as_ptr().cast()) };
                    if pointer.is_null() {
                        return Err(format!("libasound has no {}", $symbol));
                    }
                    // SAFETY: the field's type is the symbol's prototype.
                    unsafe { std::mem::transmute::<*mut c_void, _>(pointer) }
                }};
            }
            return Ok(Symbols {
                open: symbol!("snd_pcm_open"),
                close: symbol!("snd_pcm_close"),
                hw_params_malloc: symbol!("snd_pcm_hw_params_malloc"),
                hw_params_free: symbol!("snd_pcm_hw_params_free"),
                hw_params_any: symbol!("snd_pcm_hw_params_any"),
                hw_params_set_access: symbol!("snd_pcm_hw_params_set_access"),
                hw_params_set_format: symbol!("snd_pcm_hw_params_set_format"),
                hw_params_set_channels: symbol!("snd_pcm_hw_params_set_channels"),
                hw_params_set_rate_near: symbol!("snd_pcm_hw_params_set_rate_near"),
                hw_params_set_period_size_near: symbol!("snd_pcm_hw_params_set_period_size_near"),
                hw_params_set_buffer_size_near: symbol!("snd_pcm_hw_params_set_buffer_size_near"),
                hw_params: symbol!("snd_pcm_hw_params"),
                sw_params_malloc: symbol!("snd_pcm_sw_params_malloc"),
                sw_params_free: symbol!("snd_pcm_sw_params_free"),
                sw_params_current: symbol!("snd_pcm_sw_params_current"),
                sw_params_set_start_threshold: symbol!("snd_pcm_sw_params_set_start_threshold"),
                sw_params_set_avail_min: symbol!("snd_pcm_sw_params_set_avail_min"),
                sw_params: symbol!("snd_pcm_sw_params"),
                prepare: symbol!("snd_pcm_prepare"),
                drop_pcm: symbol!("snd_pcm_drop"),
                pause: symbol!("snd_pcm_pause"),
                start: symbol!("snd_pcm_start"),
                recover: symbol!("snd_pcm_recover"),
                avail_update: symbol!("snd_pcm_avail_update"),
                delay: symbol!("snd_pcm_delay"),
                writei: symbol!("snd_pcm_writei"),
                readi: symbol!("snd_pcm_readi"),
                wait: symbol!("snd_pcm_wait"),
            });
        }
        Err(error)
    });
    loaded.as_ref().ok()
}

/// What `accept` came back with: the playhead's distance, in frames, from
/// where the playhead stands to the period's last frame, read at the write.
/// The tap stamps it as the host time the sound plays at.
#[derive(Debug, Clone, Copy)]
pub struct Accepted {
    pub delay: u64,
}

/// One direction of the host's default PCM.
pub struct Handle {
    pcm: Pcm,
    playback: bool,
    frame_bytes: u64,
    /// Whether `snd_pcm_pause` was ever honored; most servers' emulation
    /// answers no, and the freeze then drops the ring instead (a pause then
    /// loses at most one ring of what was written, rather than playing it).
    pausable: AtomicBool,
    /// When the last write (or read) failed so hard `recover` could not fix
    /// it; the watchdog replaces the handle after STALL_LIMIT.
    failing: Mutex<Option<Instant>>,
}

// Sound.rs's state holds the handle under its lock and hands it between the
// stream threads; the calls themselves are single-threaded (module doc).
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}

impl Handle {
    /// Opens the default device in one direction and configures it for one
    /// stream of `params`: S16 interleaved at the guest's rate, with the
    /// ring and period the guest asked for. Any device that cannot go
    /// along returns its reason.
    pub fn open(playback: bool, params: &super::Params) -> Result<Arc<Handle>, String> {
        let Some(lib) = library() else {
            return Err("no libasound".into());
        };
        let mut pcm: Pcm = std::ptr::null_mut();
        // SAFETY: `pcm` is owned from here and closed on every way out.
        unsafe {
            if (lib.open)(&mut pcm, c"default".as_ptr(), if playback { STREAM_PLAYBACK } else { STREAM_CAPTURE }, 0) != 0 {
                return Err("no default device".into());
            }
        }
        let mut pcm = Handle {
            pcm,
            playback,
            frame_bytes: params.frame_bytes() as u64,
            pausable: AtomicBool::new(true),
            failing: Mutex::new(None),
        };
        // SAFETY: the params calls govern only this handle.
        unsafe { pcm.configure(lib, params) }?;
        Ok(Arc::new(pcm))
    }

    /// The hardware and software parameters: S16 interleaved at the guest's
    /// rate, the ring and period the guest wants, and a start threshold of
    /// one period, so the first write starts the stream the way a sound
    /// card's DMA would.
    unsafe fn configure(&mut self, lib: &Symbols, params: &super::Params) -> Result<(), String> {
        // SAFETY: the params objects are malloc'd, filled, applied, freed.
        unsafe {
            let (mut hw, mut sw): (*mut c_void, *mut c_void) = (std::ptr::null_mut(), std::ptr::null_mut());
            if (lib.hw_params_malloc)(&mut hw) != 0 || (lib.sw_params_malloc)(&mut sw) != 0 {
                (lib.hw_params_free)(hw);
                (lib.sw_params_free)(sw);
                return Err("out of memory".into());
            }
            let reason = |result: c_int, what: &str| format!("{what}: {}", -result);
            let mut dir: i32 = 0;
            // ALSA's contract on these calls is "a negative error code" —
            // where some (hw_params_any on today's stacks) answer 1 on
            // success — so anything non-negative means it went along.
            let accepted = (|| -> Result<(), String> {
                let one = |result: c_int, what: &str| {
                    if result >= 0 {
                        Ok(())
                    } else {
                        eprintln!("[vmm] sound: {what} -> {result}");
                        Err(reason(result, what))
                    }
                };
                one((lib.hw_params_any)(self.pcm, hw), "ALSA")?;
                one((lib.hw_params_set_access)(self.pcm, hw, RW_INTERLEAVED), "ALSA access")?;
                one((lib.hw_params_set_format)(self.pcm, hw, S16_LE), "ALSA format")?;
                one((lib.hw_params_set_channels)(self.pcm, hw, params.channels as u32), "ALSA channels")?;
                let mut rate = params.rate;
                one((lib.hw_params_set_rate_near)(self.pcm, hw, &mut rate, &mut dir), "ALSA rate")?;
                let period_frames = params.period_bytes as u64 / self.frame_bytes;
                let mut period = period_frames;
                one((lib.hw_params_set_period_size_near)(self.pcm, hw, &mut period, &mut dir), "ALSA period")?;
                // The guest's ring, but never less than two periods deep: a
                // ring exactly one period wide leaves the server no slack.
                let mut buffer = (params.buffer_bytes as u64 / self.frame_bytes).max(2 * period_frames);
                one((lib.hw_params_set_buffer_size_near)(self.pcm, hw, &mut buffer, &mut dir), "ALSA buffer")?;
                one((lib.hw_params)(self.pcm, hw), "ALSA")?;
                one((lib.sw_params_current)(self.pcm, sw), "ALSA")?;
                // Playback starts with the first whole period in the ring;
                // capture starts on the first read.
                one((lib.sw_params_set_start_threshold)(self.pcm, sw, period_frames), "ALSA start")?;
                one((lib.sw_params_set_avail_min)(self.pcm, sw, period_frames), "ALSA avail")?;
                one((lib.sw_params)(self.pcm, sw), "ALSA")?;
                if !self.playback {
                    one((lib.start)(self.pcm), "ALSA start")?;
                }
                Ok(())
            })();
            (lib.hw_params_free)(hw);
            (lib.sw_params_free)(sw);
            accepted
        }
    }

    /// Writes one period: accepted when the ring had room within `budget`
    /// (the device's clock waits that long and then drops, like the Mac's
    /// queue past MAX_QUEUED). Returns the playhead's distance to the
    /// period's end when it went in.
    pub fn accept(&self, pcm: &[u8], budget: Duration) -> Option<Accepted> {
        let Some(lib) = library() else { return None };
        let frames = (pcm.len() as u64 / self.frame_bytes.max(1)) as Frames;
        if frames == 0 {
            return None;
        }
        let deadline = Instant::now() + budget;
        loop {
            let room = unsafe { (lib.avail_update)(self.pcm) };
            if room >= frames {
                break;
            }
            if room < 0 && self.best_recover(lib, -room as c_int).is_none() {
                return None;
            } else if room >= 0 && Instant::now() >= deadline {
                // A ring that stays full is a healthy server that cannot
                // keep up; the period is dropped and the clock goes on.
                self.note_failing(false);
                return None;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            unsafe { (lib.wait)(self.pcm, left.as_millis().max(1).min(50) as c_int) };
        }
        // SAFETY: length and pointer agree; the room was there.
        let written = unsafe { (lib.writei)(self.pcm, pcm.as_ptr().cast(), frames as u64) };
        if written != frames {
            if written < 0 && self.best_recover(lib, -written as c_int).is_none() {
                return None;
            }
            return None;
        }
        let mut delay: Frames = 0;
        // SAFETY: delay reads the handle's own state.
        unsafe { (lib.delay)(self.pcm, &mut delay) };
        self.note_failing(true);
        Some(Accepted { delay: delay.max(0) as u64 })
    }

    /// Reads up to `out.len()` bytes, within `budget`; returns the bytes.
    /// The device's capture thread asks once per period.
    pub fn record(&self, out: &mut [u8], budget: Duration) -> Option<usize> {
        let Some(lib) = library() else { return None };
        let frames = (out.len() as u64 / self.frame_bytes.max(1)) as Frames;
        if frames == 0 {
            return None;
        }
        let deadline = Instant::now() + budget;
        loop {
            let room = unsafe { (lib.avail_update)(self.pcm) };
            if room > 0 {
                break;
            }
            if room < 0 && self.best_recover(lib, -room as c_int).is_none() {
                return None;
            } else if room == 0 && Instant::now() >= deadline {
                self.note_failing(false);
                return None;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            unsafe { (lib.wait)(self.pcm, left.as_millis().max(1).min(50) as c_int) };
        }
        // SAFETY: length and pointer agree; the room was there.
        let read = unsafe { (lib.readi)(self.pcm, out.as_mut_ptr().cast(), frames as u64) };
        if read <= 0 {
            if read < 0 && self.best_recover(lib, -read as c_int).is_none() {
                return None;
            }
            return None;
        }
        self.note_failing(true);
        Some(read as usize * self.frame_bytes as usize)
    }

    /// Stops the stream where it stands, from the clock thread at a pause's
    /// transition. `snd_pcm_pause` keeps the ring and the playhead frozen,
    /// which is what the Mac's AudioQueuePause does; where the server says
    /// no, the ring is dropped and the clock's next good write rebuilds
    /// from wherever the machine now stands (so a pause can lose at most
    /// one ring of written sound instead of playing it).
    pub fn freeze(&self) -> bool {
        let Some(lib) = library() else { return false };
        if self.pausable.load(Ordering::Relaxed) {
            // SAFETY: the pause call applies to this handle.
            unsafe {
                if (lib.pause)(self.pcm, 1) == 0 {
                    return true;
                }
            }
            self.pausable.store(false, Ordering::Relaxed);
        }
        if !self.playback {
            // Capture without pause: the ring keeps turning under the
            // sleeping thread, and a stop would change what it sees on
            // wake; nothing the guest asked for is lost either way.
            return false;
        }
        // SAFETY: the drop call applies to this handle.
        unsafe { (lib.drop_pcm)(self.pcm) };
        false
    }

    /// Lets it roll again after a freeze, from the same thread.
    pub fn thaw(&self) {
        let Some(lib) = library() else { return };
        // SAFETY: the resume call applies to this handle.
        unsafe {
            if self.pausable.load(Ordering::Relaxed) && (lib.pause)(self.pcm, 0) == 0 {
                return;
            }
            if self.playback {
                let _ = (lib.prepare)(self.pcm);
            }
        }
    }

    /// The one recover: underruns (EPIPE) and suspends (ESTRPIPE). None
    /// marks the handle dead for the watchdog to replace.
    fn best_recover(&self, lib: &Symbols, code: c_int) -> Option<()> {
        if code == EPIPE || code == ESTRPIPE {
            // SAFETY: the recover call applies to this handle.
            unsafe {
                if (lib.recover)(self.pcm, code, 1) == 0 {
                    return Some(());
                }
            }
        }
        self.note_failing(false);
        None
    }

    /// Clears the failing mark on success; plants it on first failure and
    /// leaves it (the watchdog's clock) over repeated ones.
    fn note_failing(&self, success: bool) {
        let mut slot = self.failing.lock().unwrap();
        if success {
            *slot = None;
        } else {
            slot.get_or_insert_with(Instant::now);
        }
    }

    pub fn failing_since(&self) -> Option<Duration> {
        self.failing.lock().unwrap().map(|at| at.elapsed())
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        if let Some(lib) = library() {
            // SAFETY: the handle is owned to the end here.
            unsafe { (lib.close)(self.pcm) };
        }
    }
}

#[cfg(all(test, not(target_os = "macos")))]
mod tests {
    use super::*;
    use super::super::Params;

    fn params() -> Params {
        // Two periods in a 4096-byte ring at 48 kHz stereo, the guest asking
        // for just under 43 ms of ring.
        Params { buffer_bytes: 4096, period_bytes: 1024, channels: 2, rate: 48000 }
    }

    /// These are the machine's own default device: run with
    /// `AVO_TEST_ALSA=1 cargo test -p avo-vmm alsa` where there is audio;
    /// any other machine answers with the card's failures.
    #[test]
    fn periods_go_in_and_the_playhead_is_where_the_tap_wants_it() {
        if std::env::var_os("AVO_TEST_ALSA").is_none() {
            return;
        }
        let handle = Handle::open(true, &params()).expect("AVO_TEST_ALSA says there is audio");
        let period = vec![0u8; params().period_bytes as usize];
        let first = handle.accept(&period, Duration::from_millis(10)).expect("the first period goes in");
        assert!(first.delay > 0, "the playhead reaches past the written period");
        let second = handle.accept(&period, Duration::from_millis(10)).expect("the second period goes in");
        assert!(second.delay >= first.delay, "the ring holds one more period: {first:?} vs {second:?}");
        // Let the ring drain out — an underrun on some devices, not on
        // others — and go on: either way the next period lands. This is the
        // recover the watchdog rests on.
        std::thread::sleep(Duration::from_millis(300));
        let again = handle.accept(&period, Duration::from_millis(10)).expect("the ring refilled anyway");
        assert!(again.delay > 0);
        // The pause's freeze and thaw leave the device writable.
        handle.freeze();
        handle.thaw();
        let after = handle.accept(&period, Duration::from_millis(10));
        if let Some(accepted) = after {
            assert!(accepted.delay > 0);
        }
        eprintln!("[alsa] delays: {first:?} {second:?} {again:?} {after:?}");
    }

    #[test]
    fn capture_returns_frames() {
        if std::env::var_os("AVO_TEST_ALSA").is_none() {
            return;
        }
        let handle = Handle::open(false, &params()).expect("AVO_TEST_ALSA says there is audio");
        let mut period = vec![0u8; params().period_bytes as usize];
        let bytes = handle.record(&mut period, Duration::from_millis(250)).expect("a source grants data or times out");
        assert!(bytes <= period.len());
        assert_eq!(bytes % 4, 0, "frames, not stray bytes, come out");
    }
}
