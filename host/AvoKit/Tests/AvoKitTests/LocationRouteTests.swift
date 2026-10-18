import Foundation
import Testing
@testable import AvoKit

@Suite struct GeoTests {
    static let pontianak = GeoPoint(latitude: -0.0263, longitude: 109.3425)
    static let mempawah = GeoPoint(latitude: 0.3617, longitude: 108.9599)

    @Test func distancesAndBearingsMatchKnownValues() {
        // One degree of latitude is 111.2 km on the mean sphere.
        let north = Geo.distance(GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 1, longitude: 0))
        #expect(abs(north - 111_195) < 1)
        #expect(abs(Geo.bearing(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 1, longitude: 0))) < 1e-9)
        #expect(abs(Geo.bearing(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: 1)) - 90) < 1e-9)
        #expect(abs(Geo.bearing(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: -1, longitude: 0)) - 180) < 1e-9)
        #expect(abs(Geo.bearing(from: GeoPoint(latitude: 0, longitude: 0), to: GeoPoint(latitude: 0, longitude: -1)) - 270) < 1e-9)
        // Pontianak to Mempawah, about 61 km to the north-west (315°).
        let distance = Geo.distance(Self.pontianak, Self.mempawah)
        #expect(distance > 60_000 && distance < 62_000)
        let bearing = Geo.bearing(from: Self.pontianak, to: Self.mempawah)
        #expect(bearing > 310 && bearing < 320)
        #expect(Geo.distance(Self.pontianak, Self.pontianak) == 0)
    }

    @Test func interpolationFollowsTheGreatCircle() {
        let a = Self.pontianak, b = Self.mempawah
        #expect(Geo.interpolate(a, b, 0) == GeoPoint(latitude: a.latitude, longitude: a.longitude))
        let middle = Geo.interpolate(a, b, 0.5)
        #expect(abs(Geo.distance(a, middle) - Geo.distance(middle, b)) < 0.01)
        #expect(abs(Geo.distance(a, middle) + Geo.distance(middle, b) - Geo.distance(a, b)) < 0.01)
        let end = Geo.interpolate(a, b, 1)
        #expect(Geo.distance(end, b) < 0.001)
        // Across the antimeridian, the short way round.
        let west = GeoPoint(latitude: 0, longitude: 179.9), east = GeoPoint(latitude: 0, longitude: -179.9)
        let across = Geo.interpolate(west, east, 0.5)
        #expect(abs(abs(across.longitude) - 180) < 1e-6)
        let close = Geo.interpolate(GeoPoint(latitude: 0, longitude: 179.999_999_9), GeoPoint(latitude: 0, longitude: -179.999_999_9), 0.5)
        #expect(abs(abs(close.longitude) - 180) < 1e-6)
        // Heights in between when both have one.
        let up = Geo.interpolate(GeoPoint(latitude: 0, longitude: 0, altitude: 10), GeoPoint(latitude: 0, longitude: 0.01, altitude: 30), 0.25)
        #expect(up.altitude == 15)
    }
}

@Suite struct RouteFileTests {
    static let gpx = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
      <metadata><name>Morning walk</name></metadata>
      <wpt lat="1" lon="1"><name>Not part of the track</name></wpt>
      <trk>
        <name>Track name</name>
        <trkseg>
          <trkpt lat="-0.0263" lon="109.3425"><ele>3.5</ele><time>2026-10-18T07:30:00Z</time></trkpt>
          <trkpt lat="-0.0253" lon="109.3425"><ele>4</ele><time>2026-10-18T07:30:10.500Z</time></trkpt>
        </trkseg>
        <trkseg>
          <trkpt lat="-0.0243" lon="109.3425"><time>2026-10-18T14:31:00+07:00</time></trkpt>
        </trkseg>
      </trk>
    </gpx>
    """

    @Test func gpxTracksKeepTheirPointsTimesAndHeights() throws {
        let route = try LocationRoute.parse(Data(Self.gpx.utf8), fileName: "walk.gpx")
        #expect(route.name == "Morning walk")
        #expect(route.points.count == 3)
        #expect(route.points[0] == GeoPoint(latitude: -0.0263, longitude: 109.3425, altitude: 3.5))
        #expect(route.points[2].altitude == nil)
        let times = try #require(route.times)
        #expect(zip(times, [0, 10.5, 60]).allSatisfy { abs($0 - $1) < 0.001 } && times.count == 3)
        #expect(abs((route.duration ?? 0) - 60) < 0.001)
        #expect(abs(route.distance - 222.4) < 0.5)
    }

    @Test func gpxRoutesAndWaypointsWhenThereIsNoTrack() throws {
        let gpx = """
        <gpx xmlns="http://www.topografix.com/GPX/1/0"><rte><rtept lat="1" lon="2"/><rtept lat="1.001" lon="2"/></rte>
        <wpt lat="9" lon="9"/></gpx>
        """
        let route = try LocationRoute.parse(Data(gpx.utf8), fileName: "Errands.gpx")
        #expect(route.points.map(\.latitude) == [1, 1.001])
        #expect(route.times == nil)
        #expect(route.name == "Errands")
        let waypoints = try LocationRoute.parse(Data(#"<gpx><wpt lat="9" lon="8"/><wpt lat="91" lon="8"/></gpx>"#.utf8))
        #expect(waypoints.points == [GeoPoint(latitude: 9, longitude: 8)])
    }

    @Test func gpxTimesAreDroppedUnlessEveryPointHasOneInOrder() throws {
        let missing = #"<gpx><trk><trkseg><trkpt lat="1" lon="1"><time>2026-10-18T07:30:00Z</time></trkpt><trkpt lat="1.1" lon="1"/></trkseg></trk></gpx>"#
        #expect(try LocationRoute.parse(Data(missing.utf8)).times == nil)
        let backwards = """
        <gpx><trk><trkseg><trkpt lat="1" lon="1"><time>2026-10-18T07:30:00Z</time></trkpt>
        <trkpt lat="1.1" lon="1"><time>2026-10-18T07:29:00Z</time></trkpt></trkseg></trk></gpx>
        """
        let route = try LocationRoute.parse(Data(backwards.utf8))
        #expect(route.times == nil)
        #expect(route.points.count == 2)
    }

    @Test func kmlLineStringsPointsAndTracks() throws {
        let line = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Ride</name>
          <Placemark><name>Start</name><Point><coordinates>109.30,-0.02,0</coordinates></Point></Placemark>
          <Placemark><LineString><coordinates>
            109.3425,-0.0263,5 109.3435,-0.0263
            109.3445,-0.0263,7
          </coordinates></LineString></Placemark>
        </Document></kml>
        """
        let route = try LocationRoute.parse(Data(line.utf8))
        #expect(route.name == "Ride")
        #expect(route.points == [GeoPoint(latitude: -0.0263, longitude: 109.3425, altitude: 5),
                                 GeoPoint(latitude: -0.0263, longitude: 109.3435),
                                 GeoPoint(latitude: -0.0263, longitude: 109.3445, altitude: 7)])
        let points = """
        <kml><Document><Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>
        <Placemark><Point><coordinates>3,4,5</coordinates></Point></Placemark></Document></kml>
        """
        #expect(try LocationRoute.parse(Data(points.utf8)).points == [GeoPoint(latitude: 2, longitude: 1), GeoPoint(latitude: 4, longitude: 3, altitude: 5)])
        let track = """
        <kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Placemark><name>Run</name>
          <gx:Track><when>2026-10-18T07:00:00Z</when><when>2026-10-18T07:00:30Z</when>
          <gx:coord>109.3425 -0.0263 3</gx:coord><gx:coord>109.3426 -0.0263 3</gx:coord></gx:Track>
        </Placemark></kml>
        """
        let recorded = try LocationRoute.parse(Data(track.utf8))
        #expect(recorded.name == "Run")
        #expect(recorded.times == [0, 30])
        #expect(recorded.points.last == GeoPoint(latitude: -0.0263, longitude: 109.3426, altitude: 3))
    }

    @Test func otherFilesAreRefused() {
        #expect(throws: RouteFileError.unreadable) { try LocationRoute.parse(Data("not xml at all".utf8)) }
        #expect(throws: RouteFileError.unreadable) { try LocationRoute.parse(Data("<html><body/></html>".utf8)) }
        #expect(throws: RouteFileError.noPoints) { try LocationRoute.parse(Data("<gpx><trk/></gpx>".utf8)) }
        #expect(throws: RouteFileError.noPoints) { try LocationRoute.parse(Data(#"<kml><Point><coordinates>200,95</coordinates></Point></kml>"#.utf8)) }
    }

    @Test func longRecordingsAreThinnedKeepingTheEnds() {
        let points = (0..<50_001).map { GeoPoint(latitude: 0, longitude: Double($0) * 0.0001) }
        let route = LocationRoute(points: points, times: points.indices.map(Double.init)).thinned(to: 1000)
        #expect(route.points.count <= 1000)
        #expect(route.points.first == points.first)
        #expect(route.points.last == points.last)
        #expect(route.times?.last == 50_000)
        #expect(route.isValid)
    }

    @Test func reversedRoutesKeepTheirTiming() {
        let route = LocationRoute(points: [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 0.001),
                                           GeoPoint(latitude: 0, longitude: 0.003)], times: [0, 10, 40])
        let back = route.reversed()
        #expect(back.points.first == route.points.last)
        #expect(back.times == [0, 30, 40])
    }
}

@Suite struct RoutePlaybackTests {
    /// Two 100 m legs east, then 100 m north (about), with times 0, 100, 100, 300.
    static let square: LocationRoute = {
        let metre = 1 / 111_195.0
        let points = [GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 100 * metre),
                      GeoPoint(latitude: 0, longitude: 100 * metre), GeoPoint(latitude: 100 * metre, longitude: 100 * metre)]
        return LocationRoute(points: points, times: [0, 100, 150, 250])
    }()

    @Test func pacedPlaybackMovesAtItsSpeedWithBearing() {
        var tracker = RouteTracker(route: Self.square)
        #expect(abs(tracker.distance - 200) < 0.01)
        let walk = LocationPlayback(pace: .walk)
        tracker.advance(by: 10, playback: walk)
        #expect(abs(tracker.travelled - 14) < 0.01)
        let fix = tracker.fix(playback: walk)
        #expect(abs(fix.speed - 1.4) < 1e-9)
        #expect(abs(fix.bearing - 90) < 0.01)
        // Driving at ×2 past the corner: the standing-still point takes no time.
        let fast = LocationPlayback(pace: .drive, multiplier: 2)
        tracker.advance(by: 4, playback: fast)
        #expect(abs(tracker.travelled - (14 + 111.2)) < 0.01)
        let turned = tracker.fix(playback: fast)
        #expect(abs(turned.bearing) < 0.01)
        #expect(abs(turned.speed - 27.8) < 1e-9)
        #expect(tracker.fix(playback: fast, paused: true).speed == 0)
        #expect(abs(tracker.remainingSeconds(playback: fast) - (200 - 125.2) / 27.8) < 0.01)
    }

    @Test func theEndHoldsOrLoops() {
        var once = RouteTracker(route: Self.square)
        once.advance(by: 1000, playback: LocationPlayback(pace: .walk))
        #expect(once.finished)
        #expect(once.progress == 1)
        let end = once.fix(playback: LocationPlayback())
        #expect(end.point == Self.square.points.last)
        #expect(end.speed == 0)
        #expect(abs(end.bearing) < 0.01)
        once.advance(by: 10, playback: LocationPlayback())
        #expect(once.finished)

        var looping = RouteTracker(route: Self.square)
        let loop = LocationPlayback(pace: .run, loop: true)
        // 1000 s at 2.8 m/s is 2800 m: 14 laps of 200 m exactly.
        looping.advance(by: 1000, playback: loop)
        #expect(!looping.finished)
        #expect(looping.travelled < 1 || looping.travelled > 199)
        looping.advance(by: 10, playback: loop)
        #expect(abs(looping.travelled - 28) < 0.5)
    }

    @Test func recordedPlaybackFollowsTheTimesAndStandsStill() {
        var tracker = RouteTracker(route: Self.square)
        let recorded = LocationPlayback(pace: .recorded)
        tracker.advance(by: 50, playback: recorded)
        #expect(abs(tracker.travelled - 50) < 0.01)
        #expect(abs(tracker.fix(playback: recorded).speed - 1) < 1e-3)
        // 100 s to the corner, then 50 s standing there.
        tracker.advance(by: 75, playback: recorded)
        #expect(abs(tracker.travelled - 100) < 0.01)
        let still = tracker.fix(playback: recorded)
        #expect(still.speed == 0)
        #expect(abs(still.bearing - 90) < 0.01)
        #expect(abs(tracker.remainingSeconds(playback: recorded) - 125) < 0.01)
        // ×5 on the last leg: 100 m in 100 recorded seconds.
        let fast = LocationPlayback(pace: .recorded, multiplier: 5)
        tracker.advance(by: 15, playback: fast)
        #expect(abs(tracker.travelled - 150) < 0.01)
        #expect(abs(tracker.fix(playback: fast).speed - 5) < 1e-3)
        // A change of pace keeps the place.
        let fraction = tracker.progress
        #expect(abs(tracker.progress - fraction) < 1e-12)
        tracker.advance(by: 0, playback: LocationPlayback(pace: .walk))
        #expect(tracker.progress == fraction)
    }

    @Test func recordedPaceNeedsTimes() {
        let drawn = LocationRoute(points: Self.square.points)
        #expect(LocationPlayback(pace: .recorded).pace(for: drawn) == .walk)
        var tracker = RouteTracker(route: drawn)
        tracker.advance(by: 10, playback: LocationPlayback(pace: .recorded))
        #expect(abs(tracker.travelled - 14) < 0.01)
    }

    @Test func seekingAndRestarting() {
        var tracker = RouteTracker(route: Self.square)
        tracker.seek(to: 0.75)
        #expect(abs(tracker.travelled - 150) < 0.01)
        #expect(abs(tracker.fix(playback: LocationPlayback()).bearing) < 0.01)
        tracker.seek(to: 1)
        #expect(tracker.finished)
        tracker.restart()
        #expect(!tracker.finished)
        #expect(tracker.travelled == 0)
        tracker.seek(to: .nan)
        #expect(tracker.travelled == 0)
    }

    @Test func aSinglePlaceIsAlreadyThere() {
        var tracker = RouteTracker(route: LocationRoute(points: [GeoPoint(latitude: 1, longitude: 2)]))
        #expect(tracker.finished)
        tracker.advance(by: 5, playback: LocationPlayback(loop: true))
        let fix = tracker.fix(playback: LocationPlayback())
        #expect(fix.point == GeoPoint(latitude: 1, longitude: 2))
        #expect(fix.speed == 0)
        // A route that goes nowhere does not spin forever when looping.
        var nowhere = RouteTracker(route: LocationRoute(points: [GeoPoint(latitude: 1, longitude: 2), GeoPoint(latitude: 1, longitude: 2)]))
        nowhere.advance(by: 5, playback: LocationPlayback(loop: true))
        #expect(nowhere.finished)
    }

    @Test func statusAndRequestsTravelAsJSON() throws {
        let request = LocationRequest.route(Self.square, LocationPlayback(pace: .drive, multiplier: 5, loop: true))
        let decoded = try JSONDecoder().decode(LocationRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
        let status = LocationStatus(source: .route, fix: RouteFix(point: GeoPoint(latitude: 1, longitude: 2), speed: 3, bearing: 4),
                                    route: RouteStatus(id: UUID(), name: "x", distance: 200, duration: 250, playback: LocationPlayback(),
                                                       travelled: 50, finished: false, paused: false, waiting: true, remaining: 30))
        #expect(try JSONDecoder().decode(LocationStatus.self, from: JSONEncoder().encode(status)) == status)
        #expect(status.route?.playing == false)
        #expect(status.route?.progress == 0.25)
    }
}
