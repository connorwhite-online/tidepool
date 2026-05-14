import Foundation
import CoreLocation
import TidepoolShared

@MainActor
final class PresenceReporter {
    private weak var locationManager: LocationManager?
    private var timer: Timer?
    private var lastReportAtForTile: [String: Date] = [:]

    // Hidden-places cache so we don't JSON-decode UserDefaults on every tick.
    // Keyed by the raw Data so any write through @AppStorage invalidates it.
    private var hiddenPlacesCacheKey: Data?
    private var hiddenPlacesCache: [HiddenPlace] = []

    // Jittered interval between reports (in seconds)
    private let minIntervalSec: TimeInterval = 15
    private let maxIntervalSec: TimeInterval = 45

    // Per-tile throttling (avoid rapid repeats for same tile)
    private let perTileMinIntervalSec: TimeInterval = 60

    // Home protection radius (meters)
    private let homeHideRadiusMeters: CLLocationDistance = 152.4 // 500 ft

    func start(using locationManager: LocationManager) {
        self.locationManager = locationManager
        scheduleNext()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        locationManager = nil
    }

    private func scheduleNext() {
        timer?.invalidate()
        let jitter = TimeInterval(Double.random(in: minIntervalSec...maxIntervalSec))
        timer = Timer.scheduledTimer(withTimeInterval: jitter, repeats: false) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        defer { scheduleNext() }
        guard let lm = locationManager, let loc = lm.latestLocation else { return }

        // Respect home + hidden places radius: do not report within 500 ft
        if let home = lm.homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if loc.distance(from: homeCL) < homeHideRadiusMeters { return }
        }
        for place in hiddenPlaces() {
            let placeCL = CLLocation(latitude: place.latitude, longitude: place.longitude)
            if loc.distance(from: placeCL) < homeHideRadiusMeters { return }
        }

        let tileString = Tiling.current.tileIdString(for: loc.coordinate)
        let now = Date()
        if let last = lastReportAtForTile[tileString], now.timeIntervalSince(last) < perTileMinIntervalSec {
            // Throttle repeats for same tile
            return
        }

        lastReportAtForTile[tileString] = now

        // Prune entries that are well past the throttle window — they can no
        // longer suppress anything and the dictionary would otherwise grow
        // unbounded over a long-lived session.
        let staleBefore = now.addingTimeInterval(-perTileMinIntervalSec * 2)
        lastReportAtForTile = lastReportAtForTile.filter { $0.value > staleBefore }

        let epochMs = Int64(now.timeIntervalSince1970 * 1000)
        let jitterMs = Int.random(in: 0...(Int(maxIntervalSec * 1000)))
        let report = PresenceReport(tileID: tileString, epochMs: epochMs, clientJitterMs: jitterMs)

        Task {
            do {
                _ = try await BackendClient.shared.reportPresence(report)
            } catch {
                print("[PresenceReporter] failed to report: \(error.localizedDescription)")
            }
        }
    }

    private func hiddenPlaces() -> [HiddenPlace] {
        let data = UserDefaults.standard.data(forKey: "hidden_places_data") ?? Data()
        if data == hiddenPlacesCacheKey { return hiddenPlacesCache }
        hiddenPlacesCacheKey = data
        hiddenPlacesCache = (try? JSONDecoder().decode([HiddenPlace].self, from: data)) ?? []
        return hiddenPlacesCache
    }
}
