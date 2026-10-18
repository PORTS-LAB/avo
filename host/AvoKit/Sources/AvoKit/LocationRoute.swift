import Foundation

// Places and routes for Android's GPS (an app window's Location panel): a
// place on Earth, a route through such places with the times they were
// recorded at, and the GPX and KML files routes come in. Distances are on a
// sphere the size of the Earth (haversine, within 0.5% of the ellipsoid),
// which is all a simulated walk or drive needs.

/// A place in WGS 84 degrees, with its height above sea level when known.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && (altitude?.isFinite ?? true)
    }
}

/// Great-circle geometry on a spherical Earth.
public enum Geo {
    /// The mean Earth radius (IUGG), in metres.
    public static let earthRadius = 6_371_008.8

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Metres between two places along the surface.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        earthRadius * angle(a, b)
    }

    /// The angle between two places seen from the Earth's centre (haversine).
    private static func angle(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = radians(a.latitude), φ2 = radians(b.latitude)
        let Δφ = φ2 - φ1, Δλ = radians(b.longitude - a.longitude)
        let h = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * atan2(sqrt(h), sqrt(max(0, 1 - h)))
    }

    /// The direction to set out in from `a` to reach `b`, in degrees
    /// clockwise from true north (0..<360), as Android's bearing is.
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = radians(a.latitude), φ2 = radians(b.latitude), Δλ = radians(b.longitude - a.longitude)
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let bearing = degrees(atan2(y, x)).truncatingRemainder(dividingBy: 360)
        return bearing < 0 ? bearing + 360 : bearing
    }

    /// The place `fraction` of the way from `a` to `b` along the great
    /// circle between them; the altitude in between too when both have one.
    public static func interpolate(_ a: GeoPoint, _ b: GeoPoint, _ fraction: Double) -> GeoPoint {
        let f = min(max(fraction, 0), 1)
        let altitude: Double? = switch (a.altitude, b.altitude) {
        case let (x?, y?): x + (y - x) * f
        case let (x, y): f < 0.5 ? x : y
        }
        let δ = angle(a, b)
        guard δ > 1e-7 else {
            // Under a metre apart: a straight line, the short way round.
            var Δλ = b.longitude - a.longitude
            if Δλ > 180 { Δλ -= 360 } else if Δλ < -180 { Δλ += 360 }
            var longitude = a.longitude + Δλ * f
            if longitude > 180 { longitude -= 360 } else if longitude < -180 { longitude += 360 }
            return GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * f, longitude: longitude, altitude: altitude)
        }
        let φ1 = radians(a.latitude), λ1 = radians(a.longitude), φ2 = radians(b.latitude), λ2 = radians(b.longitude)
        let A = sin((1 - f) * δ) / sin(δ), B = sin(f * δ) / sin(δ)
        let x = A * cos(φ1) * cos(λ1) + B * cos(φ2) * cos(λ2)
        let y = A * cos(φ1) * sin(λ1) + B * cos(φ2) * sin(λ2)
        let z = A * sin(φ1) + B * sin(φ2)
        return GeoPoint(latitude: degrees(atan2(z, sqrt(x * x + y * y))), longitude: degrees(atan2(y, x)), altitude: altitude)
    }
}

/// A route for Android's GPS to follow: places in order, and the times they
/// were recorded at when the route comes from a recording (a GPX track, a
/// KML gx:Track). Routes drawn on the map have no times.
public struct LocationRoute: Codable, Equatable, Sendable {
    /// More points than this are thinned out (a day of one-second fixes is 86,400).
    public static let maximumPoints = 20_000

    public var name: String?
    public var points: [GeoPoint]
    /// Seconds since the first point, one per point, never decreasing; nil
    /// when not recorded.
    public var times: [Double]?

    public init(name: String? = nil, points: [GeoPoint], times: [Double]? = nil) {
        self.name = name
        self.points = points
        self.times = times.flatMap { Self.validTimes($0, count: points.count) }
    }

    /// Times that can be played: one per point, none going back.
    static func validTimes(_ times: [Double], count: Int) -> [Double]? {
        guard times.count == count, count > 0, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        let first = times[0]
        return times.map { $0 - first }
    }

    /// Metres from the first point to the last, along the route.
    public var distance: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + Geo.distance($1.0, $1.1) }
    }

    /// How long the recording took, when it was one that took any time.
    public var duration: Double? {
        guard let last = times?.last, last > 0 else { return nil }
        return last
    }

    public var isValid: Bool {
        !points.isEmpty && points.count <= Self.maximumPoints && points.allSatisfy(\.isValid)
            && (times.map { Self.validTimes($0, count: points.count) == $0 } ?? true)
    }

    /// The same route with at most `limit` points: every n-th point and the
    /// last, so the shape and the times stay.
    public func thinned(to limit: Int = LocationRoute.maximumPoints) -> LocationRoute {
        guard points.count > limit, limit >= 2 else { return self }
        let step = Int((Double(points.count - 1) / Double(limit - 1)).rounded(.up))
        var indices = Array(stride(from: 0, to: points.count - 1, by: step))
        indices.append(points.count - 1)
        return LocationRoute(name: name, points: indices.map { points[$0] }, times: times.map { times in indices.map { times[$0] } })
    }

    /// The same route the other way round (times, if any, reversed with it).
    public func reversed() -> LocationRoute {
        let times = self.times.map { times in times.reversed().map { (times.last ?? 0) - $0 } }
        return LocationRoute(name: name, points: points.reversed(), times: times)
    }
}

// MARK: - GPX and KML files

/// Why a route file cannot be used.
public enum RouteFileError: Error, Equatable, LocalizedError, Sendable {
    /// Not XML, or neither GPX nor KML.
    case unreadable
    /// GPX or KML without a single usable place.
    case noPoints

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "This file is not a GPX or KML route.", bundle: .avoKit)
        case .noPoints: String(localized: "This file has no places in it.", bundle: .avoKit)
        }
    }
}

extension LocationRoute {
    /// A GPX or KML file (told apart by its root element). GPX: a track's
    /// points (every segment), else a route's, else the waypoints; times
    /// when every track point has one. KML: a gx:Track (with its times),
    /// else every LineString in order, else every Point. KMZ archives are
    /// unpacked by the caller. Long recordings are thinned out.
    public static func parse(_ data: Data, fileName: String? = nil) throws -> LocationRoute {
        let reader = RouteFileReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || reader.root != nil, let route = reader.route() else {
            throw reader.root == nil ? RouteFileError.unreadable : RouteFileError.noPoints
        }
        var named = route
        if named.name?.isEmpty ?? true {
            named.name = fileName.map { ($0 as NSString).deletingPathExtension }
        }
        return named.thinned()
    }
}

/// XMLParser's delegate for `LocationRoute.parse`: collects the places of
/// either format, by element name without namespace prefixes.
private final class RouteFileReader: NSObject, XMLParserDelegate {
    enum Format { case gpx, kml }

    private(set) var root: Format?
    private var path: [String] = []
    private var text = ""
    private var name: String?

    // GPX
    private var track: [GeoPoint] = []
    private var trackTimes: [Double?] = []
    private var routePoints: [GeoPoint] = []
    private var waypoints: [GeoPoint] = []
    private var current: GeoPoint?
    private var currentTime: Double?

    // KML
    private var gxTrack: [GeoPoint] = []
    private var gxWhen: [Double?] = []
    private var lines: [GeoPoint] = []
    private var kmlPoints: [GeoPoint] = []

    func route() -> LocationRoute? {
        switch root {
        case .gpx:
            if !track.isEmpty {
                let times = trackTimes.allSatisfy({ $0 != nil }) ? trackTimes.compactMap { $0 } : nil
                return LocationRoute(name: name, points: track, times: times)
            }
            if !routePoints.isEmpty { return LocationRoute(name: name, points: routePoints) }
            if !waypoints.isEmpty { return LocationRoute(name: name, points: waypoints) }
        case .kml:
            if !gxTrack.isEmpty {
                let times = gxWhen.count == gxTrack.count && gxWhen.allSatisfy({ $0 != nil }) ? gxWhen.compactMap { $0 } : nil
                return LocationRoute(name: name, points: gxTrack, times: times)
            }
            if !lines.isEmpty { return LocationRoute(name: name, points: lines) }
            if !kmlPoints.isEmpty { return LocationRoute(name: name, points: kmlPoints) }
        case nil:
            break
        }
        return nil
    }

    private static func local(_ name: String) -> String {
        String(name.split(separator: ":").last ?? Substring(name))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let element = Self.local(elementName)
        if path.isEmpty {
            switch element.lowercased() {
            case "gpx": root = .gpx
            case "kml": root = .kml
            default: parser.abortParsing()
            }
        }
        path.append(element)
        text = ""
        if root == .gpx, ["trkpt", "rtept", "wpt"].contains(element),
           let latitude = attributes["lat"].flatMap(Self.number), let longitude = attributes["lon"].flatMap(Self.number) {
            current = GeoPoint(latitude: latitude, longitude: longitude)
            currentTime = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let element = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        switch (root, element) {
        case (.gpx, "ele") where current != nil:
            current?.altitude = Self.number(value)
        case (.gpx, "time") where current != nil:
            currentTime = Self.time(value)
        case (.gpx, "name") where name == nil && ["metadata", "trk", "rte", "gpx"].contains(parent):
            name = value.isEmpty ? nil : value
        case (.gpx, "trkpt"), (.gpx, "rtept"), (.gpx, "wpt"):
            if let point = current, point.isValid {
                switch element {
                case "trkpt":
                    track.append(point)
                    trackTimes.append(currentTime)
                case "rtept": routePoints.append(point)
                default: waypoints.append(point)
                }
            }
            current = nil
        case (.kml, "name") where name == nil && ["Document", "Folder", "Placemark"].contains(parent):
            name = value.isEmpty ? nil : value
        case (.kml, "coordinates"):
            let points = Self.coordinates(value)
            if path.contains("LineString") || path.contains("LinearRing") {
                lines += points
            } else if path.contains("Point") {
                kmlPoints += points
            }
        case (.kml, "when") where path.contains("Track"):
            gxWhen.append(Self.time(value))
        case (.kml, "coord") where path.contains("Track"):
            // "longitude latitude altitude", separated by spaces.
            let numbers = value.split(whereSeparator: \.isWhitespace).compactMap { Self.number(String($0)) }
            if numbers.count >= 2 {
                let point = GeoPoint(latitude: numbers[1], longitude: numbers[0], altitude: numbers.count > 2 ? numbers[2] : nil)
                if point.isValid { gxTrack.append(point) }
            }
        default:
            break
        }
        path.removeLast()
        text = ""
    }

    /// KML's "longitude,latitude[,altitude]" tuples, separated by white space.
    private static func coordinates(_ text: String) -> [GeoPoint] {
        text.split(whereSeparator: \.isWhitespace).compactMap { tuple in
            let numbers = tuple.split(separator: ",").map { number(String($0)) }
            guard numbers.count >= 2, let longitude = numbers[0], let latitude = numbers[1] else { return nil }
            let point = GeoPoint(latitude: latitude, longitude: longitude, altitude: numbers.count > 2 ? numbers[2] : nil)
            return point.isValid ? point : nil
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// An ISO 8601 time ("2026-10-18T07:30:00Z", with or without fractions
    /// of a second or an offset), as seconds since 1970.
    private static func time(_ text: String) -> Double? {
        let plain = Date.ISO8601FormatStyle()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return ((try? fractional.parse(text)) ?? (try? plain.parse(text)))?.timeIntervalSince1970
    }
}
