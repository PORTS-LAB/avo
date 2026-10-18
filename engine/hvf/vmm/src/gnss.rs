//! Host side of the GNSS HAL's location device (AOSP's default GNSS HAL,
//! hardware/interfaces/gnss/common/utils/default/DeviceFileReader.cpp):
//! the HAL writes `CMD_GET_LOCATION` to /dev/gnss1 (hvc7) about once a
//! second while an app wants a fix, and reads back a "Fix" record:
//!
//! ```text
//! Fix,Provider,LatitudeDegrees,LongitudeDegrees,AltitudeMeters,SpeedMps,AccuracyMeters,
//! BearingDegrees,UnixTimeMillis,SpeedAccuracyMps,BearingAccuracyDegrees,elapsedRealtimeNanos
//! ```
//!
//! The answer ends with "\n\n\n\n" (the reader's end mark). The location comes from the
//! daemon (`location` on the control socket): the Mac's own (CoreLocation),
//! or a place or a route from an app window's Location panel, which the
//! daemon moves on four times a second with its speed and bearing. A fix
//! that moves is carried on along its bearing for up to a second when the
//! HAL reads it, so Android's once-a-second fixes are evenly spaced however
//! the daemon's updates fall between them. Android gets real GPS fixes, not
//! mock locations. Without a location the request goes unanswered, and the
//! HAL then reports its own built-in place (37.422, -122.084).

use crate::virtio::console::ConsoleInput;
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const GET_LOCATION: &[u8] = b"CMD_GET_LOCATION";
/// How far ahead of its last update a moving fix is carried on.
const MAX_DEAD_RECKONING: Duration = Duration::from_secs(1);
/// The mean Earth radius (IUGG), in metres, as the daemon's routes use it.
const EARTH_RADIUS: f64 = 6_371_008.8;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Fix {
    pub latitude: f64,
    pub longitude: f64,
    pub altitude: f64,
    pub accuracy: f64,
    pub speed: f64,
    pub bearing: f64,
}

impl Fix {
    /// `<lat> <lng> [altitude] [accuracy] [speed] [bearing]` (control socket).
    pub fn parse(words: &[&str]) -> Result<Fix, String> {
        let number = |i: usize, default: f64| -> Result<f64, String> {
            match words.get(i) {
                Some(word) => word.parse::<f64>().map_err(|_| format!("bad number {word}")),
                None => Ok(default),
            }
        };
        let fix = Fix {
            latitude: number(0, f64::NAN)?,
            longitude: number(1, f64::NAN)?,
            altitude: number(2, 0.0)?,
            accuracy: number(3, 10.0)?,
            speed: number(4, 0.0)?,
            bearing: number(5, 0.0)?,
        };
        if !(-90.0..=90.0).contains(&fix.latitude) || !(-180.0..=180.0).contains(&fix.longitude) {
            return Err("location needs <latitude> <longitude>".into());
        }
        Ok(fix)
    }

    /// Where this fix is `elapsed` later, going on at its speed along its
    /// bearing (a great circle); itself when it stands still.
    pub fn carried_on(&self, elapsed: Duration) -> Fix {
        let distance = self.speed * elapsed.min(MAX_DEAD_RECKONING).as_secs_f64();
        if !(distance > 0.0) {
            return *self;
        }
        let (φ1, λ1, θ) = (self.latitude.to_radians(), self.longitude.to_radians(), self.bearing.to_radians());
        let δ = distance / EARTH_RADIUS;
        let φ2 = (φ1.sin() * δ.cos() + φ1.cos() * δ.sin() * θ.cos()).asin();
        let λ2 = λ1 + (θ.sin() * δ.sin() * φ1.cos()).atan2(δ.cos() - φ1.sin() * φ2.sin());
        let longitude = (λ2.to_degrees() + 540.0).rem_euclid(360.0) - 180.0;
        Fix { latitude: φ2.to_degrees(), longitude, ..*self }
    }

    /// The HAL's "Fix" record, timestamped now.
    pub fn record(&self) -> String {
        let millis = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        format!(
            "Fix,GPS,{:.7},{:.7},{:.1},{:.2},{:.1},{:.1},{},0.5,1.0,0\n\n\n\n",
            self.latitude, self.longitude, self.altitude, self.speed, self.accuracy.max(1.0), self.bearing, millis
        )
    }
}

#[derive(Default)]
pub struct Gnss {
    /// The newest fix and when it came.
    fix: Mutex<Option<(Fix, Instant)>>,
    input: Mutex<Option<ConsoleInput>>,
}

impl Gnss {
    pub fn new() -> Arc<Gnss> {
        Arc::new(Gnss::default())
    }

    /// The console the answers go back on (hvc7's input).
    pub fn connect(&self, input: ConsoleInput) {
        *self.input.lock().unwrap() = Some(input);
    }

    pub fn set(&self, fix: Option<Fix>) {
        *self.fix.lock().unwrap() = fix.map(|fix| (fix, Instant::now()));
    }

    /// Guest output on /dev/gnss1.
    pub fn sink(self: &Arc<Self>) -> Box<dyn Write + Send> {
        Box::new(Requests { gnss: self.clone(), buffer: Vec::new() })
    }

    fn answer(&self) {
        let Some((fix, at)) = *self.fix.lock().unwrap() else { return };
        let fix = fix.carried_on(at.elapsed());
        if let Some(input) = self.input.lock().unwrap().as_ref() {
            input.send(fix.record().as_bytes());
        }
    }
}

struct Requests {
    gnss: Arc<Gnss>,
    buffer: Vec<u8>,
}

impl Write for Requests {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        self.buffer.extend_from_slice(data);
        while let Some(at) = self.buffer.windows(GET_LOCATION.len()).position(|w| w == GET_LOCATION) {
            self.buffer.drain(..at + GET_LOCATION.len());
            self.gnss.answer();
        }
        // Keep only what could still become the start of a request.
        if self.buffer.len() > GET_LOCATION.len() {
            let keep = self.buffer.len() - GET_LOCATION.len();
            self.buffer.drain(..keep);
        }
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixes_parse_and_render_as_the_hal_expects() {
        let fix = Fix::parse(&["-0.0263", "109.3425", "12", "8"]).unwrap();
        let record = fix.record();
        let fields: Vec<&str> = record.trim_end().split(',').collect();
        assert_eq!(fields.len(), 12);
        assert_eq!(&fields[..8], &["Fix", "GPS", "-0.0263000", "109.3425000", "12.0", "0.00", "8.0", "0.0"]);
        assert!(record.ends_with("\n\n\n\n"));
        assert!(Fix::parse(&["200", "0"]).is_err());
        assert!(Fix::parse(&["x"]).is_err());
    }

    #[test]
    fn moving_fixes_are_carried_on_for_up_to_a_second() {
        let still = Fix::parse(&["-0.0263", "109.3425"]).unwrap();
        assert_eq!(still.carried_on(Duration::from_millis(500)), still);
        // 10 m/s due east on the equator: 5 m in half a second, 10 m at most.
        let east = Fix::parse(&["0", "179.99999", "0", "5", "10", "90"]).unwrap();
        let metre = 360.0 / (2.0 * std::f64::consts::PI * EARTH_RADIUS);
        let half = east.carried_on(Duration::from_millis(500));
        assert!(half.latitude.abs() < 1e-12);
        assert!(((half.longitude - east.longitude + 360.0) % 360.0 - 5.0 * metre).abs() < 1e-9);
        let late = east.carried_on(Duration::from_secs(5));
        assert!((late.longitude + 360.0 - east.longitude - 10.0 * metre).abs() < 1e-9, "across the antimeridian: {}", late.longitude);
        assert_eq!((late.speed, late.bearing, late.accuracy), (10.0, 90.0, 5.0));
        // Due north: the latitude grows.
        let north = Fix::parse(&["10", "20", "0", "5", "2", "0"]).unwrap().carried_on(Duration::from_secs(1));
        assert!((north.latitude - 10.0 - 2.0 * metre).abs() < 1e-9 && (north.longitude - 20.0).abs() < 1e-12);
    }

    #[test]
    fn requests_split_across_writes_are_answered_once() {
        let gnss = Gnss::new();
        let mut sink = gnss.sink();
        // No location yet and no console: nothing to do, nothing breaks.
        sink.write_all(b"CMD_GET_").unwrap();
        sink.write_all(b"LOCATION").unwrap();
        gnss.set(Some(Fix::parse(&["1", "2"]).unwrap()));
        sink.write_all(b"CMD_GET_LOC").unwrap();
        sink.write_all(b"ATION").unwrap();
    }
}
