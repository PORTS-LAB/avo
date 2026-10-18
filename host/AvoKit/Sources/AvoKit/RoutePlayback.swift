import Foundation

// A route as Android's GPS plays it (the daemon's LocationCenter moves it
// on several times a second): where along the route it is, and the fix
// Android gets there, with its speed and bearing. Pure, so it is testable.

/// How fast a route plays.
public enum LocationPace: String, Codable, CaseIterable, Sendable {
    case walk, run, cycle, drive
    /// At the times it was recorded (only routes with times).
    case recorded

    /// Metres per second at ×1; nil for `recorded`, whose speed varies.
    public var metresPerSecond: Double? {
        switch self {
        case .walk: 1.4 // 5 km/h
        case .run: 2.8 // 10 km/h
        case .cycle: 5 // 18 km/h
        case .drive: 13.9 // 50 km/h
        case .recorded: nil
        }
    }
}

/// How a route plays: its pace, how much faster than that, and whether it
/// starts over at the end.
public struct LocationPlayback: Codable, Equatable, Sendable {
    /// What the Location panel offers.
    public static let multipliers: [Double] = [1, 2, 5, 10, 20]

    public var pace: LocationPace
    public var multiplier: Double
    public var loop: Bool

    public init(pace: LocationPace = .walk, multiplier: Double = 1, loop: Bool = false) {
        self.pace = pace
        self.multiplier = multiplier
        self.loop = loop
    }

    /// The pace the route really plays at: `recorded` needs a route that took time.
    public func pace(for route: LocationRoute) -> LocationPace {
        pace == .recorded && route.duration == nil ? .walk : pace
    }

    var factor: Double { multiplier.isFinite && multiplier > 0 ? multiplier : 1 }
}

/// Where Android is, how fast it goes (metres per second) and which way
/// (degrees clockwise from true north).
public struct RouteFix: Codable, Equatable, Sendable {
    public var point: GeoPoint
    public var speed: Double
    public var bearing: Double

    public init(point: GeoPoint, speed: Double = 0, bearing: Double = 0) {
        self.point = point
        self.speed = speed
        self.bearing = bearing
    }
}

/// A route being played: on segment `segment` (from point `segment` to the
/// next), `fraction` of the way along it. The fraction is the same whether
/// the segment is measured in metres (a pace) or in recorded seconds, so a
/// change of pace keeps the place. A recording standing still for a while
/// is a segment with no length that still takes its time.
public struct RouteTracker: Equatable, Sendable {
    public let route: LocationRoute
    public private(set) var segment = 0
    public private(set) var fraction = 0.0
    /// Played to the end, and not looping.
    public private(set) var finished = false
    /// Metres of each segment, and where each point is along the route.
    private let lengths: [Double]
    private let starts: [Double]
    /// Recorded seconds of each segment, and when each point was recorded.
    private let durations: [Double]?
    /// Metres along the whole route.
    public let distance: Double

    public init(route: LocationRoute) {
        self.route = route
        let points = route.points
        lengths = zip(points, points.dropFirst()).map { Geo.distance($0, $1) }
        var starts = [0.0]
        for length in lengths { starts.append(starts[starts.count - 1] + length) }
        self.starts = starts
        distance = starts.last ?? 0
        durations = route.times.map { times in zip(times, times.dropFirst()).map { $1 - $0 } }
        finished = lengths.isEmpty
    }

    private var segments: Int { lengths.count }

    /// Metres played so far (of this lap).
    public var travelled: Double {
        guard segment < segments else { return distance }
        return starts[segment] + lengths[segment] * fraction
    }

    /// How much of the route is played, 0...1.
    public var progress: Double { distance > 0 ? min(travelled / distance, 1) : (finished ? 1 : 0) }

    /// Recorded seconds played so far.
    private var recordedTime: Double {
        guard let times = route.times else { return 0 }
        guard segment < segments, let durations else { return times.last ?? 0 }
        return times[segment] + durations[segment] * fraction
    }

    /// Moves on by `seconds` of real time at `playback`'s pace. At the end
    /// the route starts over when it loops, else it stays at its last point.
    public mutating func advance(by seconds: Double, playback: LocationPlayback) {
        guard seconds > 0, seconds.isFinite, !finished else { return }
        let recorded = playback.pace(for: route) == .recorded
        let sizes = recorded ? (durations ?? lengths) : lengths
        let total = sizes.reduce(0, +)
        guard total > 0 else {
            end()
            return
        }
        var budget = recorded ? seconds * playback.factor : seconds * (playback.pace(for: route).metresPerSecond ?? 1.4) * playback.factor
        // Whole laps change nothing.
        if playback.loop, budget > total { budget = budget.truncatingRemainder(dividingBy: total) + total }
        while budget > 0 {
            if segment >= segments {
                guard playback.loop else {
                    end()
                    return
                }
                segment = 0
                fraction = 0
            }
            let size = sizes[segment]
            let left = size * (1 - fraction)
            if size <= 0 || budget >= left {
                budget -= max(left, 0)
                segment += 1
                fraction = 0
            } else {
                fraction += budget / size
                budget = 0
            }
        }
        if segment >= segments, !playback.loop { end() }
    }

    private mutating func end() {
        segment = segments
        fraction = 0
        finished = true
    }

    /// Back to the first point.
    public mutating func restart() {
        segment = 0
        fraction = 0
        finished = segments == 0
    }

    /// Jumps to `progress` (0...1) of the route's length.
    public mutating func seek(to progress: Double) {
        let target = min(max(progress.isFinite ? progress : 0, 0), 1) * distance
        guard segments > 0, target < distance else {
            if segments > 0, progress >= 1 { end() } else { restart() }
            return
        }
        // The last segment that starts at or before the target and has a length.
        var index = 0
        for candidate in 0..<segments where starts[candidate] <= target && lengths[candidate] > 0 { index = candidate }
        segment = index
        fraction = lengths[index] > 0 ? min(max((target - starts[index]) / lengths[index], 0), 0.999_999) : 0
        finished = false
    }

    /// Where Android is now, and how fast and which way it goes there.
    public func fix(playback: LocationPlayback, paused: Bool = false) -> RouteFix {
        let points = route.points
        guard segment < segments else {
            return RouteFix(point: points[points.count - 1], speed: 0, bearing: lastBearing(before: segments))
        }
        let from = points[segment], to = points[segment + 1]
        let point = Geo.interpolate(from, to, fraction)
        let length = lengths[segment]
        let bearing: Double
        if length <= 0 {
            bearing = lastBearing(before: segment)
        } else if length * (1 - fraction) > 1 {
            // Along a great circle the heading drifts: from here to the segment's end.
            bearing = Geo.bearing(from: point, to: to)
        } else {
            bearing = Geo.bearing(from: from, to: to)
        }
        var speed = 0.0
        if !paused {
            if playback.pace(for: route) == .recorded, let durations {
                speed = durations[segment] > 0 ? length / durations[segment] * playback.factor : 0
            } else if length > 0 {
                speed = (playback.pace(for: route).metresPerSecond ?? 0) * playback.factor
            }
        }
        return RouteFix(point: point, speed: speed, bearing: bearing)
    }

    /// The heading of the nearest segment with a length before `index`
    /// (else after it); 0 for a route that goes nowhere.
    private func lastBearing(before index: Int) -> Double {
        let points = route.points
        for candidate in stride(from: min(index, segments) - 1, through: 0, by: -1) where lengths[candidate] > 0 {
            return Geo.bearing(from: points[candidate], to: points[candidate + 1])
        }
        for candidate in index..<segments where lengths[candidate] > 0 {
            return Geo.bearing(from: points[candidate], to: points[candidate + 1])
        }
        return 0
    }

    /// Seconds of real time until the end of this lap at `playback`.
    public func remainingSeconds(playback: LocationPlayback) -> Double {
        guard !finished else { return 0 }
        if playback.pace(for: route) == .recorded, let duration = route.duration {
            return max(duration - recordedTime, 0) / playback.factor
        }
        let speed = (playback.pace(for: route).metresPerSecond ?? 1.4) * playback.factor
        return max(distance - travelled, 0) / speed
    }
}
