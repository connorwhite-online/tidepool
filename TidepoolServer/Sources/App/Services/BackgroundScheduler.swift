import Vapor
import SQLKit

/// Spawns background async loops on server boot for tidepool computation and cache warming.
struct BackgroundScheduler: LifecycleHandler {
    func didBoot(_ app: Application) throws {
        app.logger.info("[BackgroundScheduler] Starting background loops...")

        // Tidepool computation loop
        Task {
            // Wait a bit for the server to fully initialize
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s

            while !Task.isCancelled {
                await runTidepoolComputation(app: app)

                // Check every hour for stale tidepools
                try? await Task.sleep(nanoseconds: 3600_000_000_000) // 1 hour
            }
        }

        // Stale user check loop (for triggered recomputes)
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s initial delay

            while !Task.isCancelled {
                await recomputeStaleUsers(app: app)

                // Check every 5 minutes for users who need recomputation
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 min
            }
        }
    }

    /// Full batch computation — runs when tidepools are stale or haven't been computed.
    private func runTidepoolComputation(app: Application) async {
        guard let sql = app.db as? SQLDatabase else { return }

        // Check if any tidepools need computing
        let staleCount = try? await sql.raw(SQLQueryString("""
            SELECT COUNT(*) as count FROM device_profiles
            WHERE quality != 'poor'
              AND (tidepool_computed_at IS NULL OR tidepool_computed_at < now() - interval '24 hours')
            """)).all(decoding: CountRow.self)

        let count = staleCount?.first?.count ?? 0
        if count > 0 {
            app.logger.info("[BackgroundScheduler] \(count) users need tidepool computation")
            await TidepoolComputeService.computeAll(app: app)
        }
    }

    /// Check for individual users whose vectors were updated (tidepool_computed_at = NULL).
    private func recomputeStaleUsers(app: Application) async {
        guard let sql = app.db as? SQLDatabase else { return }

        let staleUsers = try? await sql.raw(SQLQueryString("""
            SELECT device_id::text as device_id FROM device_profiles
            WHERE tidepool_computed_at IS NULL AND quality != 'poor'
            LIMIT 10
            """)).all(decoding: DeviceIDRow.self)

        guard let staleUsers, !staleUsers.isEmpty else { return }

        for user in staleUsers {
            app.logger.info("[BackgroundScheduler] Recomputing tidepool for \(user.device_id)")
            await TidepoolComputeService.computeForUser(deviceID: user.device_id, app: app)
        }
    }

    private struct CountRow: Decodable { let count: Int }
    private struct DeviceIDRow: Decodable { let device_id: String }
}
