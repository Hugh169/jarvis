import Foundation
import CoreLocation
import MapKit

/// Where this Mac is, and how long it takes to get somewhere else.
///
/// Deliberately native. CoreLocation and MapKit need no API key, no billing
/// account and no OAuth, which is the entire reason these exist rather than a
/// Google Directions client. The trade is precision: a Mac has no GPS and
/// triangulates from Wi-Fi, so a fix is street-level at best. Good enough for
/// "how long to school", useless for turn-by-turn.
public enum LocationError: Error, LocalizedError, Equatable {
    case denied
    case servicesOff
    case promptNeverAppeared
    case unavailable
    /// Carries the authorisation state, because "it timed out" on its own is
    /// indistinguishable between a Mac that can't see Wi-Fi and one that never
    /// got asked for permission.
    case timedOut(status: String)
    case noSuchPlace(String)
    case noRoute(String)

    public var errorDescription: String? {
        switch self {
        case .denied:
            "Location access is off for JARVIS. Turn it on in System Settings, "
            + "under Privacy and Security, then Location Services."
        case .servicesOff:
            "Location Services is switched off for this Mac entirely. Turn it on in "
            + "System Settings, under Privacy and Security, then Location Services."
        case .promptNeverAppeared:
            "macOS never asked for location permission, so I can't tell where you are. "
            + "Tell me where you are and I'll work from that."
        case .unavailable:
            "Couldn't get a location fix."
        case .timedOut(let status):
            "Locating this Mac took too long (authorisation: \(status))."
        case .noSuchPlace(let query):
            "Couldn't find anywhere called \"\(query)\"."
        case .noRoute(let place):
            "Couldn't work out a route to \(place)."
        }
    }
}

/// One shared location fix, briefly cached.
///
/// The cache is load-bearing rather than an optimisation: a turn like "how long
/// to work, and what's near me" fires several of these tools concurrently, and
/// a cold fix costs seconds each time.
///
/// Uses `CLLocationManager` rather than the tidier `CLLocationUpdate.liveUpdates()`
/// because on macOS that sequence never asks for authorisation — it simply
/// produces nothing, forever, and the turn dies on a timeout with no prompt
/// ever shown and nothing in the TCC log. Authorisation has to be requested
/// explicitly, which means the delegate.
///
/// Main-actor rather than an actor of its own: `CLLocationManager` must be
/// created on a thread with a run loop and delivers its callbacks there.
@MainActor
public final class LocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    public static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation, Error>] = []
    private var cached: (location: CLLocation, at: Date)?
    private var timeoutTask: Task<Void, Never>?
    private var promptTask: Task<Void, Never>?

    private static let cacheLifetime: TimeInterval = 60
    private static let fixTimeout: Duration = .seconds(12)

    public override init() {
        super.init()
        manager.delegate = self
        // Street-level is all a Mac can do anyway, and asking for less
        // precision returns sooner.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    public func current() async throws -> CLLocation {
        if let cached, Date.now.timeIntervalSince(cached.at) < Self.cacheLifetime {
            return cached.location
        }
        let location = try await requestFix()
        cached = (location, .now)
        return location
    }

    /// Forgets the cached fix — for tests, and after a long sleep.
    public func invalidate() {
        cached = nil
    }

    /// The timeout is a sibling task rather than a raced task group: a group
    /// mixing a main-actor child with a non-isolated one defeats the
    /// region-based isolation checker outright ("pattern that the region-based
    /// isolation checker does not understand how to check").
    private func requestFix() async throws -> CLLocation {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            armTimeout()
            start()
        }
    }

    /// A Mac that can't see any known Wi-Fi never produces a fix and never
    /// errors either, so without this the turn hangs indefinitely.
    private func armTimeout() {
        guard timeoutTask == nil else { return }
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.fixTimeout)
            guard let self, !Task.isCancelled, !self.waiters.isEmpty else { return }
            self.deliver(.failure(LocationError.timedOut(status: self.statusDescription)))
        }
    }

    /// Asking for authorisation should either raise a prompt or flip the status
    /// within a moment. On this build it does neither — `locationd` and `tccd`
    /// never log the request at all, and the status sits at `notDetermined`
    /// forever. Until that's resolved, fail in three seconds with something
    /// actionable rather than making every turn wait out the full fix timeout.
    private func armPromptWatchdog() {
        promptTask?.cancel()
        promptTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, !self.waiters.isEmpty,
                  self.manager.authorizationStatus == .notDetermined else { return }
            self.deliver(.failure(LocationError.promptNeverAppeared))
        }
    }

    /// What the authorisation state actually is, in words. Reported on failure
    /// because a silent timeout is otherwise impossible to tell apart from a
    /// permission that was never requested.
    var statusDescription: String {
        let services = CLLocationManager.locationServicesEnabled() ? "on" : "OFF"
        let state = switch manager.authorizationStatus {
        case .notDetermined: "not determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        @unknown default: "unknown"
        }
        return "\(state), services \(services)"
    }

    /// Asking before we're authorised gets a `denied` error back rather than a
    /// prompt, so this waits for the authorisation callback and starts there.
    private func start() {
        // The global switch outranks the per-app grant: with it off there is
        // no prompt and no callback, just silence until the timeout.
        guard CLLocationManager.locationServicesEnabled() else {
            deliver(.failure(LocationError.servicesOff))
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            // macOS has no when-in-use tier, only Always, so this is the right
            // call — but see `armPromptWatchdog`: on this build the request
            // never reaches locationd at all.
            manager.requestAlwaysAuthorization()
            armPromptWatchdog()
        case .denied, .restricted:
            deliver(.failure(LocationError.denied))
        default:
            manager.requestLocation()
        }
    }

    private func deliver(_ result: Result<CLLocation, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        promptTask?.cancel()
        promptTask = nil
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(with: result) }
    }

    // MARK: CLLocationManagerDelegate

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            deliver(.failure(LocationError.denied))
        case .notDetermined:
            break
        default:
            guard !waiters.isEmpty else { return }
            manager.requestLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        deliver(.success(location))
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient `kCLErrorLocationUnknown` means it is still trying;
        // anything else is terminal for this attempt.
        if (error as? CLError)?.code == .locationUnknown { return }
        deliver(.failure(error))
    }
}

/// MapKit and geocoding work, kept on the main actor: none of these types are
/// Sendable and MapKit expects the main thread anyway.
///
/// Every entry point returns plain values rather than MapKit objects. That
/// isn't tidiness — an `MKMapItem` or `MKRoute` cannot leave the main actor at
/// all under strict concurrency, so a whole operation has to complete here and
/// hand back something inert.
@MainActor
enum MapLookup {
    struct Estimate: Sendable {
        let name: String
        /// What was actually used, which is not always what was asked for.
        let mode: TravelMode
        let seconds: TimeInterval
        let metres: CLLocationDistance
        let arrival: Date
    }

    struct Route: Sendable {
        let name: String
        let via: String
        let mode: TravelMode
        let seconds: TimeInterval
        let metres: CLLocationDistance
        let steps: [String]
    }

    struct Place: Sendable {
        let name: String
        let metres: CLLocationDistance?
    }

    /// A spoken place name for a fix — suburb and state, not a postal address.
    static func placeName(for location: CLLocation) async -> String? {
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil
        }
        let locality = mark.locality ?? mark.subLocality ?? mark.name
        let parts = [locality, mark.administrativeArea].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Transit is the awkward mode: Apple only has schedules in some regions,
    /// so it fails where a car route would have worked. Rather than sink a turn
    /// that was answerable, fall back to driving and report which was used.
    static func estimate(
        to query: String,
        near location: CLLocation,
        mode requested: TravelMode
    ) async throws -> Estimate {
        let destination = try await resolve(query, near: location)
        let name = destination.name ?? query
        do {
            let response = try await calculateETA(from: location, to: destination, mode: requested)
            return Estimate(
                name: name, mode: requested,
                seconds: response.expectedTravelTime,
                metres: response.distance,
                arrival: response.expectedArrivalDate
            )
        } catch where requested == .transit {
            let response = try await calculateETA(from: location, to: destination, mode: .driving)
            return Estimate(
                name: name, mode: .driving,
                seconds: response.expectedTravelTime,
                metres: response.distance,
                arrival: response.expectedArrivalDate
            )
        }
    }

    static func route(
        to query: String,
        near location: CLLocation,
        mode: TravelMode
    ) async throws -> Route {
        let destination = try await resolve(query, near: location)
        let name = destination.name ?? query

        let request = MKDirections.Request()
        request.source = mapItem(for: location)
        request.destination = destination
        request.transportType = mode.transportType
        guard let response = try? await MKDirections(request: request).calculate(),
              let first = response.routes.first else {
            throw LocationError.noRoute(name)
        }

        let steps = first.steps
            .map(\.instructions)
            .filter { !$0.isEmpty }
        return Route(
            name: name, via: first.name, mode: mode,
            seconds: first.expectedTravelTime,
            metres: first.distance,
            steps: steps
        )
    }

    static func nearby(
        _ query: String,
        near location: CLLocation,
        limit: Int
    ) async throws -> [Place] {
        try await search(query, near: location, limit: limit).map { item in
            Place(
                name: item.name ?? "Unnamed",
                metres: item.placemark.location?.distance(from: location)
            )
        }
    }

    // MARK: Internals — MapKit objects never escape past here

    private static func resolve(_ query: String, near location: CLLocation) async throws -> MKMapItem {
        guard let first = try await search(query, near: location, limit: 1).first else {
            throw LocationError.noSuchPlace(query)
        }
        return first
    }

    /// Biased to near the user. Without the region bias "the station" resolves
    /// to one on another continent.
    private static func search(
        _ query: String,
        near location: CLLocation,
        limit: Int
    ) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: 40_000,
            longitudinalMeters: 40_000
        )
        guard let response = try? await MKLocalSearch(request: request).start(),
              !response.mapItems.isEmpty else {
            throw LocationError.noSuchPlace(query)
        }
        return Array(response.mapItems.prefix(limit))
    }

    private static func mapItem(for location: CLLocation) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
    }

    private static func calculateETA(
        from location: CLLocation,
        to destination: MKMapItem,
        mode: TravelMode
    ) async throws -> MKDirections.ETAResponse {
        let request = MKDirections.Request()
        request.source = mapItem(for: location)
        request.destination = destination
        request.transportType = mode.transportType
        guard let response = try? await MKDirections(request: request).calculateETA() else {
            throw LocationError.noRoute(destination.name ?? "there")
        }
        return response
    }
}

/// Shared vocabulary for the travel tools.
enum TravelMode: String, CaseIterable, Sendable {
    case driving, walking, transit

    static func parse(_ raw: String?) -> TravelMode {
        guard let raw = raw?.lowercased() else { return .driving }
        return switch raw {
        case "walk", "walking", "on foot": .walking
        case "transit", "public transport", "public", "bus", "train": .transit
        default: .driving
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .driving: .automobile
        case .walking: .walking
        case .transit: .transit
        }
    }

    /// How it reads in a spoken sentence.
    var phrase: String {
        switch self {
        case .driving: "driving"
        case .walking: "walking"
        case .transit: "on public transport"
        }
    }
}

/// Formats a duration the way it should be said, not the way it should be read.
enum SpokenDuration {
    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded() / 60)
        if total < 1 { return "less than a minute" }
        if total < 60 { return "\(total) minute\(total == 1 ? "" : "s")" }
        let hours = total / 60
        let minutes = total % 60
        let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
        guard minutes > 0 else { return hourPart }
        return "\(hourPart) \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// `MKDistanceFormatter` isn't Sendable, so this stays on the main actor
    /// rather than being constructed wherever it happens to be called.
    @MainActor
    static func distance(_ metres: CLLocationDistance) -> String {
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .full
        return formatter.string(fromDistance: metres)
    }
}

// MARK: - Tools

public struct WhereAmITool: JarvisTool {
    public static let name = "where_am_i"
    public static let description = """
        The Mac's current location, as a place name and coordinates. Use this \
        before anything that depends on where the user is. Accuracy is \
        street-level, not GPS.
        """
    public static let inputSchema: JSONValue = ["type": "object", "properties": [:]]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        let location = try await LocationProvider.shared.current()
        let coordinates = String(
            format: "%.4f, %.4f",
            location.coordinate.latitude,
            location.coordinate.longitude
        )
        guard let name = await MapLookup.placeName(for: location) else {
            return ToolResult(content: "Location: \(coordinates) (no place name available).")
        }
        return ToolResult(content: "\(name). Coordinates \(coordinates).")
    }
}

public struct TravelTimeTool: JarvisTool {
    public static let name = "travel_time_to"
    public static let description = """
        How long it takes to get from where the user is now to somewhere else, \
        and how far it is. Accepts a place name, an address, or a business \
        ("the nearest Woolworths"). Modes: driving, walking, transit.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "destination": [
                "type": "string",
                "description": "Where to. A place name, address or business.",
            ],
            "mode": [
                "type": "string",
                "enum": ["driving", "walking", "transit"],
                "description": "How they're travelling. Default driving.",
            ],
        ],
        "required": ["destination"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["destination"]?.stringValue, !query.isEmpty else {
            return .error("No destination given.")
        }
        let requested = TravelMode.parse(input["mode"]?.stringValue)
        let location = try await LocationProvider.shared.current()
        let estimate = try await MapLookup.estimate(to: query, near: location, mode: requested)

        let duration = SpokenDuration.describe(estimate.seconds)
        let distance = await SpokenDuration.distance(estimate.metres)
        let arrival = estimate.arrival.formatted(date: .omitted, time: .shortened)

        var sentence = "\(estimate.name) is \(duration) away \(estimate.mode.phrase) — "
            + "\(distance), arriving about \(arrival)."
        if estimate.mode != requested {
            sentence += " There's no public transport data for this area, so that's driving."
        }
        return ToolResult(content: sentence)
    }
}

public struct DirectionsTool: JarvisTool {
    public static let name = "directions_to"
    public static let description = """
        Step-by-step directions from where the user is now to somewhere else. \
        Only use this when they actually want the route; for "how long will it \
        take" use travel_time_to instead. Send the steps to display_detail \
        rather than reading them aloud.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "destination": ["type": "string", "description": "Where to."],
            "mode": [
                "type": "string",
                "enum": ["driving", "walking", "transit"],
                "description": "How they're travelling. Default driving.",
            ],
        ],
        "required": ["destination"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["destination"]?.stringValue, !query.isEmpty else {
            return .error("No destination given.")
        }
        let mode = TravelMode.parse(input["mode"]?.stringValue)
        let location = try await LocationProvider.shared.current()
        let route = try await MapLookup.route(to: query, near: location, mode: mode)

        var lines = [
            "\(route.name) — \(SpokenDuration.describe(route.seconds)) \(route.mode.phrase), "
            + "\(await SpokenDuration.distance(route.metres))."
        ]
        if !route.via.isEmpty { lines.append("Via \(route.via).") }
        for (index, step) in route.steps.enumerated() {
            lines.append("\(index + 1). \(step)")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}

public struct NearbyTool: JarvisTool {
    public static let name = "nearby"
    public static let description = """
        Places of a given kind near the user — "petrol station", "pharmacy", \
        "coffee". Returns names with distances. Say the best one or two aloud \
        and send the rest to display_detail.
        """
    public static let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "What to look for."],
            "limit": ["type": "integer", "description": "How many results, 1 to 10. Default 5."],
        ],
        "required": ["query"],
    ]

    public init() {}

    public func execute(_ input: JSONValue) async throws -> ToolResult {
        guard let query = input["query"]?.stringValue, !query.isEmpty else {
            return .error("Nothing to look for.")
        }
        let limit = max(1, min(10, Int(input["limit"]?.numberValue ?? 5)))
        let location = try await LocationProvider.shared.current()
        let places = try await MapLookup.nearby(query, near: location, limit: limit)

        var lines: [String] = []
        for place in places {
            guard let metres = place.metres else {
                lines.append(place.name)
                continue
            }
            lines.append("\(place.name) — \(await SpokenDuration.distance(metres))")
        }
        return ToolResult(content: lines.joined(separator: "\n"))
    }
}
