import Foundation
import CoreLocation
import TidepoolShared

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

        // Respect home + hidden places radius: do not report within 500 ft
        if let home = lm.homeLocation {
            let homeCL = CLLocation(latitude: home.latitude, longitude: home.longitude)
            if loc.distance(from: homeCL) < homeHideRadiusMeters { return }
        }
        if let data = UserDefaults.standard.data(forKey: "hidden_places_data"),
           let places = try? JSONDecoder().decode([HiddenPlace].self, from: data) {
            for place in places {
                let placeCL = CLLocation(latitude: place.latitude, longitude: place.longitude)
                if loc.distance(from: placeCL) < homeHideRadiusMeters { return }
            }
        }

        let tileString = Tiling.current.tileIdString(for: loc.coordinate)
        let now = Date()
        if let last = lastReportAtForTile[tileString], now.timeIntervalSince(last) < perTileMinIntervalSec {
            // Throttle repeats for same tile
            return
        }

        lastReportedTileString = tileString
        lastReportAtForTile[tileString] = now

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
} 