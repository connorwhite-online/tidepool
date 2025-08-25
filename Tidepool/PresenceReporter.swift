import Foundation
import CoreLocation

final class PresenceReporter {
    private weak var locationManager: LocationManager?
    private var timer: Timer?
    private var lastReportedTileString: String?
    private var lastReportAtForTile: [String: Date] = [:]

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

        // Respect home radius: do not report when within 500 ft of Home
        if let home = lm.homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            let distance = loc.distance(from: homeCL)
            if distance < homeHideRadiusMeters { return }
        }

        let tileString = Tiling.current.tileIdString(for: loc.coordinate)
        let now = Date()
        if let last = lastReportAtForTile[tileString], now.timeIntervalSince(last) < perTileMinIntervalSec {
            // Throttle repeats for same tile
            return
        }

        lastReportedTileString = tileString
        lastReportAtForTile[tileString] = now

        // Stub: log instead of network call
        let epochMs = Int(now.timeIntervalSince1970 * 1000)
        let jitterMs = Int.random(in: 0...(Int(maxIntervalSec * 1000)))
        print("[PresenceReporter] would send tile_id=\(tileString) epoch_ms=\(epochMs) client_jitter_ms=\(jitterMs)")
    }
} 