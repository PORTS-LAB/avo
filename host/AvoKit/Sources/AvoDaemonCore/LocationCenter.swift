import AvoKit
import Foundation
import os

// What Android's GPS reports (an app window's Location panel): this Mac's
// own location, a place chosen on the map, or a route played at a pace.
// The daemon owns it, so a route keeps playing with every window closed.
// A route moves on four times a second while Android runs and stands still
// while it is stopped or paused; Android's GNSS HAL reads the newest fix
// about once a second (gnss.rs in the engine), with its speed and bearing.

/// An engine that can tell Android's GPS where it is.
public protocol LocationEngine: AnyObject, Sendable {
    /// nil: no fix.
    func setLocation(_ fix: LocationFix?) async
}

extension VMMEngine: LocationEngine {}

actor LocationCenter {
    /// How often a playing route moves on.
    static let tick: Duration = .milliseconds(250)
    /// How often the panels hear about it while it moves (ticks).
    static let ticksPerUpdate = 4
    /// What Android is told of a simulated fix's accuracy, in metres.
    static let accuracy = 5.0

    enum Source {
        case mac
        case point(GeoPoint, name: String?)
        case route(Playing)
    }

    struct Playing {
        let id = UUID()
        var tracker: RouteTracker
        var playback: LocationPlayback
        var paused = false
    }

    /// Every change for the panels (the route's points left out).
    nonisolated let updates: AsyncStream<LocationStatus>
    private let continuation: AsyncStream<LocationStatus>.Continuation
    private let engine: (any LocationEngine)?
    /// Lets a paused Android go on (VMManager.wake).
    private let wake: @Sendable () async -> Void
    private let logger = Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Location")

    private(set) var source = Source.mac
    /// The Mac's own location as CoreLocation last gave it (MacLocation).
    private var macFix: LocationFix?
    private var macSharing = true
    /// Android runs and is not paused: a route moves only then.
    private var androidRunning = false
    private var ticker: Task<Void, Never>?
    private var lastTick: SuspendingClock.Instant?
    private var ticksSinceUpdate = 0

    init(engine: (any LocationEngine)?, wake: @escaping @Sendable () async -> Void = {}) {
        self.engine = engine
        self.wake = wake
        (updates, continuation) = AsyncStream.makeStream(of: LocationStatus.self, bufferingPolicy: .bufferingNewest(4))
    }

    // MARK: What it hears

    /// From CoreLocation (nil: unknown, not shared, or Android stopped).
    func macLocationChanged(_ fix: LocationFix?) async {
        macFix = fix
        if case .mac = source { await engine?.setLocation(fix) }
        publish()
    }

    /// Settings › Privacy & Security › Share this Mac’s location with Android.
    func sharingChanged(_ sharing: Bool) {
        guard sharing != macSharing else { return }
        macSharing = sharing
        publish()
    }

    /// Android runs (and is not paused), or not: a route goes on or waits.
    func androidChanged(running: Bool) {
        guard running != androidRunning else { return }
        androidRunning = running
        updateTicker()
        publish()
    }

    /// A route plays (Pause When Idle waits for it).
    var isPlaying: Bool {
        guard case .route(let playing) = source else { return false }
        return !playing.paused && !playing.tracker.finished
    }

    // MARK: What the panels ask

    func status(withPoints: Bool = false) -> LocationStatus {
        let mac = macFix.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude) }
        var status = LocationStatus(source: .mac, mac: mac, macSharing: macSharing)
        switch source {
        case .mac:
            status.fix = macFix.map { RouteFix(point: GeoPoint(latitude: $0.latitude, longitude: $0.longitude, altitude: $0.altitude),
                                               speed: $0.speed, bearing: $0.bearing) }
        case let .point(point, name):
            status.source = .point
            status.fix = RouteFix(point: point)
            status.pointName = name
        case .route(let playing):
            status.source = .route
            status.fix = playing.tracker.fix(playback: playing.playback, paused: playing.paused || !androidRunning)
            let route = playing.tracker.route
            status.route = RouteStatus(id: playing.id, name: route.name, distance: playing.tracker.distance,
                                       duration: route.duration, playback: playing.playback,
                                       travelled: playing.tracker.travelled, finished: playing.tracker.finished,
                                       paused: playing.paused, waiting: !androidRunning,
                                       remaining: playing.tracker.remainingSeconds(playback: playing.playback),
                                       points: withPoints ? route : nil)
        }
        return status
    }

    func change(_ request: LocationRequest) async throws -> LocationStatus {
        switch request {
        case .mac:
            source = .mac
            await engine?.setLocation(macFix)
        case let .point(point, name):
            guard point.isValid else { throw AvoError.internalError(String(localized: "That place is not on Earth.", bundle: .avoKit)) }
            source = .point(point, name: name)
            await sendFix()
        case let .route(route, playback):
            guard route.isValid else { throw AvoError.internalError(String(localized: "That route cannot be played.", bundle: .avoKit)) }
            source = .route(Playing(tracker: RouteTracker(route: route), playback: playback))
            logger.notice("route: \(route.points.count) points, \(Int(route.distance)) m, \(playback.pace.rawValue, privacy: .public) ×\(playback.multiplier)")
            await sendFix()
            await wakeForRoute()
        case .playback(let playback):
            guard case .route(var playing) = source else { break }
            playing.playback = playback
            source = .route(playing)
            await sendFix()
        case .pause:
            guard case .route(var playing) = source else { break }
            playing.paused = true
            source = .route(playing)
            await sendFix()
        case .resume:
            guard case .route(var playing) = source else { break }
            if playing.tracker.finished { playing.tracker.restart() }
            playing.paused = false
            source = .route(playing)
            await sendFix()
            await wakeForRoute()
        case .seek(let progress):
            guard case .route(var playing) = source else { break }
            playing.tracker.seek(to: progress)
            source = .route(playing)
            await sendFix()
        }
        updateTicker()
        publish()
        return status()
    }

    // MARK: Playing a route

    private func wakeForRoute() async {
        guard isPlaying else { return }
        await wake()
    }

    /// Ticks while a route plays and Android runs; none otherwise.
    private func updateTicker() {
        let wanted = isPlaying && androidRunning
        if wanted, ticker == nil {
            lastTick = SuspendingClock.now
            ticksSinceUpdate = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.tick, clock: .suspending)
                    guard !Task.isCancelled else { return }
                    await self?.tick()
                }
            }
        } else if !wanted, let ticker {
            ticker.cancel()
            self.ticker = nil
            lastTick = nil
        }
    }

    private func tick() async {
        guard case .route(var playing) = source, ticker != nil else { return }
        let now = SuspendingClock.now
        // The Mac's sleep does not count (a suspending clock), nor does a
        // stall beyond two seconds.
        let elapsed = min(lastTick.map { now - $0 } ?? .zero, .seconds(2))
        lastTick = now
        playing.tracker.advance(by: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                                playback: playing.playback)
        source = .route(playing)
        let finished = playing.tracker.finished
        ticksSinceUpdate += 1
        if finished || ticksSinceUpdate >= Self.ticksPerUpdate {
            ticksSinceUpdate = 0
            publish()
        }
        if finished { updateTicker() }
        await sendFix()
    }

    /// The simulated fix to the engine, which keeps it for Android.
    private func sendFix() async {
        guard let fix = status().fix else { return }
        await engine?.setLocation(LocationFix(latitude: fix.point.latitude, longitude: fix.point.longitude,
                                              altitude: fix.point.altitude ?? 0, accuracy: Self.accuracy,
                                              speed: fix.speed, bearing: fix.bearing))
    }

    private func publish() {
        continuation.yield(status())
    }
}

// MARK: - The daemon's side (XPC `location(watch:)`, `changeLocation`)

extension DaemonCore {
    /// Starts following Android's status and the setting, and passes every
    /// change on to the panels that watch.
    func startLocation() {
        let location = self.location
        Task { [weak self] in
            for await status in location.updates { await self?.sendLocation(status) }
        }
        Task { [weak self] in
            guard let statuses = await self?.statusChanges() else { return }
            for await status in statuses { await location.androidChanged(running: status.state == .running && !status.isPaused) }
        }
        Task { [weak self] in
            guard let configs = await self?.configChanges() else { return }
            for await config in configs { await location.sharingChanged(config.shareLocation) }
        }
    }

    private func sendLocation(_ status: LocationStatus) {
        for id in locationWatchers { send(.location(status), toClient: id) }
    }

    /// What Android's GPS reports, with the route's points; `watch`: the
    /// caller hears every change (`DaemonEvent.location`) until it says
    /// false or goes. App Shims and Control Panels.
    public func locationStatus(watch: Bool, client: ClientID) async throws -> LocationStatus {
        guard let role = role(of: client), role != .engine else { throw AvoError.unauthorizedCaller }
        if watch { locationWatchers.insert(client) } else { locationWatchers.remove(client) }
        return await location.status(withPoints: true)
    }

    /// The Location panel's changes: this Mac's location, a place, a route and how it plays.
    public func changeLocation(_ request: LocationRequest, client: ClientID) async throws -> LocationStatus {
        guard let role = role(of: client), role != .engine else { throw AvoError.unauthorizedCaller }
        return try await location.change(request)
    }

    /// The Mac's own location from CoreLocation (the daemon's MacLocation).
    public func macLocationChanged(_ fix: LocationFix?) async {
        await location.macLocationChanged(fix)
    }
}
