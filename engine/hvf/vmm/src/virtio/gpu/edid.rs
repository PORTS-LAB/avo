//! EDIDs for the scanouts (VIRTIO_GPU_F_EDID, VIRTIO_GPU_CMD_GET_EDID): how
//! a display's refresh rate reaches Android. Without one the guest's
//! virtio-gpu driver makes up a 60 Hz CVT mode for the scanout's size.
//!
//! Cuttlefish's composer (ranchu, `display_finder_mode=drm`) gives
//! SurfaceFlinger one mode per display, the connector's first: the
//! preferred timing here, the scanout's size at its rate. The other rates
//! of `RATES` follow it, for a composer that would offer them all. Its
//! vsync thread ticks at that rate, and SurfaceFlinger can render at the
//! rate or a divisor of it (`peak_refresh_rate`, `min_refresh_rate`). A
//! new rate takes a re-plug: the composer ignores new modes of a
//! connected display, as it does new sizes.
//!
//! The identity is that of the composer's own fallback EDIDs (`GGL`,
//! product 1, `EMU_display_<n>`, `Display::setLegacyEdid`): in Software
//! the composer hands the EDID on to SurfaceFlinger, whose display ids
//! (`local:…`) come from it and stay what they were. The physical size is
//! 0 like theirs, so DPIs still come from the density.
//!
//! Timings with little blanking, the pixel clock chosen so the rate comes
//! out exact for any whole rate (a Mac screen's own 75 Hz too): in the base
//! block's detailed timings (three, up to 4095 pixels and 655.35 MHz), else
//! in a DisplayID extension (type I timings), which a 4K display at 120 Hz
//! needs, and a rate besides `RATES` (four timings). The test VM's kernel
//! and composer take both (75 Hz at 1080×2400 and 3840×2160).

/// Rates every EDID offers, after the scanout's own.
pub const RATES: [u32; 3] = [60, 90, 120];
/// A scanout's rate unless it was plugged with another.
pub const DEFAULT_RATE: u32 = 60;
/// Rates a scanout may run at.
pub const RATE_RANGE: std::ops::RangeInclusive<u32> = 24..=240;

const H_BLANK: u32 = 80;
const H_FRONT: u32 = 8;
const H_SYNC: u32 = 32;
const V_BLANK: u32 = 20;
const V_FRONT: u32 = 3;
const V_SYNC: u32 = 5;

/// One mode: active size, rate and the pixel clock that gives it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Timing {
    width: u32,
    height: u32,
    /// In units of 10 kHz, as both timing formats count it.
    clock: u64,
}

impl Timing {
    fn new(width: u32, height: u32, hz: u32) -> Timing {
        let total = (width + H_BLANK) as u64 * (height + V_BLANK) as u64;
        Timing { width, height, clock: (total * hz as u64 + 5_000) / 10_000 }
    }

    /// Whether a base-block detailed timing can hold it.
    fn fits_dtd(&self) -> bool {
        self.width <= 4095 && self.height <= 4095 && self.clock <= u16::MAX as u64
    }

    /// The 18-byte detailed timing descriptor (EDID 1.3 §3.10.2).
    fn dtd(&self) -> [u8; 18] {
        let mut d = [0u8; 18];
        let (w, h) = (self.width, self.height);
        d[0..2].copy_from_slice(&(self.clock as u16).to_le_bytes());
        d[2] = w as u8;
        d[3] = H_BLANK as u8;
        d[4] = ((w >> 8) << 4 | (H_BLANK >> 8)) as u8;
        d[5] = h as u8;
        d[6] = V_BLANK as u8;
        d[7] = ((h >> 8) << 4 | (V_BLANK >> 8)) as u8;
        d[8] = H_FRONT as u8;
        d[9] = H_SYNC as u8;
        d[10] = ((V_FRONT & 0xf) << 4 | (V_SYNC & 0xf)) as u8;
        d[11] = ((H_FRONT >> 8) << 6 | (H_SYNC >> 8) << 4 | (V_FRONT >> 4) << 2 | (V_SYNC >> 4)) as u8;
        // 12..15: size 0 mm, no borders. Digital separate sync, both positive.
        d[17] = 0x1e;
        d
    }

    /// The 20-byte DisplayID type I detailed timing (values minus one).
    fn displayid(&self, preferred: bool) -> [u8; 20] {
        let mut t = [0u8; 20];
        let clock = (self.clock - 1) as u32;
        t[0..3].copy_from_slice(&clock.to_le_bytes()[..3]);
        // Preferred, progressive, aspect ratio undefined.
        t[3] = if preferred { 0x88 } else { 0x08 };
        let mut put = |at: usize, value: u32| t[at..at + 2].copy_from_slice(&((value - 1) as u16).to_le_bytes());
        put(4, self.width);
        put(6, H_BLANK);
        put(8, H_FRONT);
        put(10, H_SYNC);
        put(12, self.height);
        put(14, V_BLANK);
        put(16, V_FRONT);
        put(18, V_SYNC);
        // Positive sync polarities.
        t[9] |= 0x80;
        t[17] |= 0x80;
        t
    }
}

fn checksum(block: &mut [u8]) {
    let sum = block[..block.len() - 1].iter().fold(0u8, |a, b| a.wrapping_add(*b));
    *block.last_mut().unwrap() = sum.wrapping_neg();
}

/// The EDID of scanout `index` at `width`×`height` and `hz`; empty for a
/// scanout without a size (unplugged: no monitor, no EDID).
pub fn edid(index: usize, width: u32, height: u32, hz: u32) -> Vec<u8> {
    if width == 0 || height == 0 || hz == 0 {
        return Vec::new();
    }
    let rates = std::iter::once(hz).chain(RATES.into_iter().filter(|&r| r != hz));
    let timings: Vec<Timing> = rates.map(|r| Timing::new(width, height, r)).collect();
    let in_base = timings.len() <= 3 && timings.iter().all(Timing::fits_dtd);

    let mut base = [0u8; 128];
    base[0..8].copy_from_slice(&[0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00]);
    // GGL, product 1, serial 1, week 27 of 2006, EDID 1.3, digital input,
    // no size, gamma 2.2, RGB with a preferred timing, the fallback's colours.
    base[8..20].copy_from_slice(&[0x1c, 0xec, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1b, 0x10, 0x01, 0x03]);
    base[20..35].copy_from_slice(&[0x80, 0, 0, 0x78, 0x0a, 0x0d, 0xc9, 0xa0, 0x57, 0x47, 0x98, 0x27, 0x12, 0x48, 0x4c]);
    // No established timings; standard timings unused.
    base[38..54].fill(0x01);
    let mut slots = [[0u8; 18]; 3];
    for (slot, descriptor) in slots.iter_mut().enumerate() {
        *descriptor = match timings.get(slot) {
            Some(timing) if in_base => timing.dtd(),
            // Dummy descriptor.
            _ => [0, 0, 0, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        };
    }
    for (slot, descriptor) in slots.iter().enumerate() {
        base[54 + slot * 18..72 + slot * 18].copy_from_slice(descriptor);
    }
    // Display name, 13 bytes: the fallback's, '0' + index included.
    base[108..113].copy_from_slice(&[0, 0, 0, 0xfc, 0]);
    base[113..125].copy_from_slice(b"EMU_display_");
    base[125] = b'0'.wrapping_add(index as u8);
    if in_base {
        checksum(&mut base);
        return base.to_vec();
    }

    base[126] = 1;
    checksum(&mut base);
    let mut extension = [0u8; 128];
    extension[0] = 0x70;
    let count = timings.len().min(5);
    let block_len = 20 * count;
    // DisplayID 1.2 section: revision, payload bytes, extension section, no more.
    extension[1..5].copy_from_slice(&[0x12, (3 + block_len) as u8, 0, 0]);
    extension[5..8].copy_from_slice(&[0x03, 0x00, block_len as u8]);
    for (i, timing) in timings.iter().take(count).enumerate() {
        extension[8 + i * 20..28 + i * 20].copy_from_slice(&timing.displayid(i == 0));
    }
    // The section's checksum follows its payload.
    let end = 8 + block_len;
    checksum(&mut extension[1..=end]);
    checksum(&mut extension);
    let mut out = base.to_vec();
    out.extend_from_slice(&extension);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A mode the way Linux reads it (drm_edid.c): size, totals, clock in kHz, preferred.
    #[derive(Debug, PartialEq)]
    struct Mode {
        width: u32,
        height: u32,
        htotal: u32,
        vtotal: u32,
        khz: u64,
        preferred: bool,
    }

    impl Mode {
        /// The refresh rate as the composer rounds it (DrmConnector::getRefreshRateUint).
        fn hz(&self) -> u32 {
            (1000.0 * self.khz as f32 / (self.vtotal as f32 * self.htotal as f32) + 0.5) as u32
        }
    }

    fn sums_to_zero(bytes: &[u8]) -> bool {
        bytes.iter().fold(0u8, |a, b| a.wrapping_add(*b)) == 0
    }

    /// drm_mode_detailed and drm_mode_displayid_detailed, without the quirks.
    fn parse(edid: &[u8]) -> Vec<Mode> {
        assert!(edid.len() % 128 == 0 && !edid.is_empty());
        assert_eq!(&edid[0..8], &[0, 255, 255, 255, 255, 255, 255, 0]);
        assert!(sums_to_zero(&edid[..128]), "base checksum");
        assert_eq!(edid[126] as usize, edid.len() / 128 - 1, "extension count");
        let preferred_bit = edid[24] & 0x02 != 0;
        let mut modes = Vec::new();
        for slot in 0..4 {
            let d = &edid[54 + slot * 18..72 + slot * 18];
            let clock = u16::from_le_bytes([d[0], d[1]]) as u64;
            if clock == 0 {
                continue;
            }
            let width = (d[4] as u32 & 0xf0) << 4 | d[2] as u32;
            let hblank = (d[4] as u32 & 0x0f) << 8 | d[3] as u32;
            let height = (d[7] as u32 & 0xf0) << 4 | d[5] as u32;
            let vblank = (d[7] as u32 & 0x0f) << 8 | d[6] as u32;
            let hsync = (d[11] as u32 & 0x30) << 4 | d[9] as u32;
            let vsync = (d[11] as u32 & 0x03) << 4 | (d[10] as u32 & 0x0f);
            assert!(hsync > 0 && vsync > 0, "Linux drops a timing without sync pulses");
            assert_eq!(d[17] & 0x18, 0x18, "separate sync");
            let first = modes.is_empty();
            modes.push(Mode { width, height, htotal: width + hblank, vtotal: height + vblank, khz: clock * 10,
                              preferred: preferred_bit && first });
        }
        if edid.len() > 128 {
            let ext = &edid[128..256];
            assert!(sums_to_zero(ext), "extension checksum");
            assert_eq!(ext[0], 0x70);
            let bytes = ext[2] as usize;
            assert!(sums_to_zero(&ext[1..1 + 4 + bytes + 1]), "DisplayID section checksum");
            assert_eq!(ext[5], 0x03, "type I timings");
            let len = ext[7] as usize;
            assert_eq!(len % 20, 0);
            assert_eq!(bytes, 3 + len);
            for t in ext[8..8 + len].chunks(20) {
                let word = |at: usize| u16::from_le_bytes([t[at], t[at + 1]]) as u32;
                let clock = (t[0] as u64 | (t[1] as u64) << 8 | (t[2] as u64) << 16) + 1;
                let (width, hblank) = (word(4) + 1, word(6) + 1);
                let (height, vblank) = (word(12) + 1, word(14) + 1);
                assert!(t[9] & 0x80 != 0 && t[17] & 0x80 != 0, "positive sync");
                modes.push(Mode { width, height, htotal: width + hblank, vtotal: height + vblank, khz: clock * 10,
                                  preferred: t[3] & 0x80 != 0 });
            }
        }
        modes
    }

    #[test]
    fn the_preferred_mode_is_the_scanouts_size_at_its_rate() {
        for hz in [60, 90, 120] {
            let bytes = edid(1, 720, 1280, hz);
            assert_eq!(bytes.len(), 128, "fits the base block");
            let modes = parse(&bytes);
            assert_eq!(modes.len(), 3);
            assert!(modes[0].preferred && modes.iter().skip(1).all(|m| !m.preferred));
            assert_eq!((modes[0].width, modes[0].height, modes[0].hz()), (720, 1280, hz));
            // The other rates follow, same size.
            let mut rates: Vec<u32> = modes.iter().map(Mode::hz).collect();
            rates.sort();
            assert_eq!(rates, [60, 90, 120]);
            assert!(modes.iter().all(|m| (m.width, m.height) == (720, 1280)));
        }
    }

    #[test]
    fn rates_come_out_exact_for_every_size() {
        for (w, h) in [(64, 64), (720, 1280), (1080, 2400), (1440, 3200), (2560, 1600), (3840, 2160), (4096, 2160), (8192, 8192)] {
            for hz in [30, 60, 75, 90, 120, 144, 240] {
                let modes = parse(&edid(2, w, h, hz));
                assert_eq!((modes[0].width, modes[0].height), (w, h), "{w}x{h}@{hz}");
                assert_eq!(modes[0].hz(), hz, "{w}x{h}@{hz}");
                assert!(modes[0].preferred);
                // Within 0.01 Hz, so SurfaceFlinger's vsync period is the rate's.
                let exact = modes[0].khz as f64 * 1000.0 / (modes[0].htotal as f64 * modes[0].vtotal as f64);
                assert!((exact - hz as f64).abs() < 0.01 || w * h < 10_000, "{w}x{h}@{hz}: {exact}");
            }
        }
    }

    /// Android runs at any whole rate from 60 to 120 Hz (a Mac screen's own
    /// 75 or 100): exact and preferred, the others of `RATES` after it,
    /// each once, at phone sizes and 4K.
    #[test]
    fn every_rate_android_runs_at_is_exact() {
        for hz in 60..=120 {
            for (w, h) in [(720, 1280), (1080, 2400), (1440, 3200), (2560, 1600), (3840, 2160)] {
                let modes = parse(&edid(1, w, h, hz));
                assert!(modes[0].preferred && modes.iter().skip(1).all(|m| !m.preferred), "{w}x{h}@{hz}");
                assert_eq!((modes[0].width, modes[0].height, modes[0].hz()), (w, h, hz));
                let exact = modes[0].khz as f64 * 1000.0 / (modes[0].htotal as f64 * modes[0].vtotal as f64);
                assert!((exact - hz as f64).abs() < 0.01, "{w}x{h}@{hz}: {exact}");
                let mut rates: Vec<u32> = modes.iter().map(Mode::hz).collect();
                rates.sort();
                let mut expected: Vec<u32> = RATES.into_iter().chain([hz]).collect();
                expected.sort();
                expected.dedup();
                assert_eq!(rates, expected, "{w}x{h}@{hz}");
            }
        }
    }

    #[test]
    fn big_or_fast_modes_go_into_a_displayid_extension() {
        // 3840x2160 fits a detailed timing at 60 Hz, not at 120 (1.03 GHz).
        let bytes = edid(3, 3840, 2160, 120);
        assert_eq!(bytes.len(), 256);
        let modes = parse(&bytes);
        assert_eq!(modes.len(), 3, "every mode in the extension, none in the base block");
        assert!(modes[0].preferred && modes[0].hz() == 120 && modes[0].khz > 655_350);
        assert_eq!(parse(&edid(3, 1080, 1920, 120)).len(), 3);
        // A rate outside RATES makes four modes: the extension holds them.
        let odd = parse(&edid(1, 1080, 1920, 75));
        assert_eq!(odd.iter().map(Mode::hz).collect::<Vec<_>>(), [75, 60, 90, 120]);
    }

    #[test]
    fn the_identity_is_the_composers_fallback() {
        // Display::setLegacyEdid's EMU_display_1 up to the timings: GGL, product 1,
        // serial 1, week 27 of 2006, EDID 1.3 (the physical size is 0 here, as in
        // the fallback's timing).
        let bytes = edid(1, 720, 1280, 60);
        assert_eq!(&bytes[8..21], &[0x1c, 0xec, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1b, 0x10, 0x01, 0x03, 0x80]);
        assert_eq!(&bytes[108..126], b"\0\0\0\xfc\0EMU_display_1");
        assert_eq!(&bytes[21..23], &[0, 0], "no physical size");
        assert!(bytes[54 + 12..54 + 15].iter().all(|&b| b == 0), "no size in the timing either");
        // The fallback's quirk for ten and up ('0' + 10 is ':').
        assert_eq!(edid_name(&edid(10, 720, 1280, 60)), b"EMU_display_:");
    }

    fn edid_name(edid: &[u8]) -> &[u8] {
        &edid[113..126]
    }

    #[test]
    fn an_unplugged_scanout_has_no_edid() {
        assert!(edid(4, 0, 0, 60).is_empty());
        assert!(edid(4, 720, 1280, 0).is_empty());
    }
}
