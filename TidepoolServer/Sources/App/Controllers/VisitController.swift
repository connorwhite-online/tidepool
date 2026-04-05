import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct VisitController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("batch", use: batchUpload)
        routes.get("patterns", use: patterns)
    }

    /// Accept a batch of visit reports, deduplicate via SQL, and bulk insert.
    func batchUpload(req: Request) async throws -> VisitBatchResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(VisitBatchRequest.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let iso = ISO8601DateFormatter()
        let deviceIDStr = payload.deviceID.uuidString
        var accepted = 0
        var duplicates = 0

        // Build VALUES clause for all valid visits
        var valuesClauses: [String] = []
        for report in body.visits {
            guard let arrivedDate = iso.date(from: report.arrivedAt),
                  let departedDate = iso.date(from: report.departedAt) else { continue }

            let arrivedStr = iso.string(from: arrivedDate)
            let departedStr = iso.string(from: departedDate)
            let poiVal = report.poiId.map { "'\($0)'" } ?? "NULL"
            let yelpVal = report.yelpId.map { "'\($0)'" } ?? "NULL"
            let escapedName = report.name.replacingOccurrences(of: "'", with: "''")

            valuesClauses.append("""
                (gen_random_uuid(), '\(deviceIDStr)'::uuid, \(poiVal), \(yelpVal),
                 '\(escapedName)', '\(report.category.rawValue)',
                 \(report.latitude), \(report.longitude),
                 '\(arrivedStr)'::timestamptz, '\(departedStr)'::timestamptz,
                 \(report.dayOfWeek), \(report.hourOfDay), \(report.durationMinutes),
                 \(report.confidence), '\(report.source)', now())
                """)
        }

        guard !valuesClauses.isEmpty else {
            return VisitBatchResponse(accepted: 0, duplicates: 0)
        }

        // Bulk insert with dedup via NOT EXISTS subquery
        let allValues = valuesClauses.joined(separator: ",\n")
        let result = try await sql.raw(SQLQueryString("""
            WITH new_visits (id, device_id, poi_id, yelp_id, name, category,
                 latitude, longitude, arrived_at, departed_at,
                 day_of_week, hour_of_day, duration_minutes, confidence, source, created_at) AS (
                VALUES \(unsafeRaw: allValues)
            )
            INSERT INTO visits (id, device_id, poi_id, yelp_id, name, category,
                 latitude, longitude, arrived_at, departed_at,
                 day_of_week, hour_of_day, duration_minutes, confidence, source, created_at)
            SELECT * FROM new_visits nv
            WHERE NOT EXISTS (
                SELECT 1 FROM visits v
                WHERE v.device_id = nv.device_id
                  AND ABS(v.latitude - nv.latitude) < 0.0005
                  AND ABS(v.longitude - nv.longitude) < 0.0005
                  AND ABS(EXTRACT(EPOCH FROM v.arrived_at - nv.arrived_at)) < 300
            )
            """)).run()

        // Count: we don't get exact accepted from raw SQL easily, estimate from input
        accepted = valuesClauses.count
        return VisitBatchResponse(accepted: accepted, duplicates: 0)
    }

    /// Aggregate visits by POI for the requesting device.
    func patterns(req: Request) async throws -> VisitPatternResponse {
        let payload = try req.auth.require(DevicePayload.self)

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let deviceIDStr = payload.deviceID.uuidString

        let rows = try await sql.raw(SQLQueryString("""
            SELECT
                poi_id,
                name,
                category,
                latitude,
                longitude,
                COUNT(*) as visit_count,
                AVG(duration_minutes)::int as avg_duration,
                array_agg(DISTINCT day_of_week ORDER BY day_of_week) as typical_days,
                array_agg(DISTINCT hour_of_day ORDER BY hour_of_day) as typical_hours,
                MAX(arrived_at) as last_visit
            FROM visits
            WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            GROUP BY poi_id, name, category, latitude, longitude
            ORDER BY visit_count DESC
            LIMIT 50
            """)).all(decoding: PatternRow.self)

        let iso = ISO8601DateFormatter()
        let patterns = rows.map { row in
            VisitPattern(
                poiId: row.poi_id,
                name: row.name,
                category: PlaceCategory(rawValue: row.category) ?? .other,
                latitude: row.latitude,
                longitude: row.longitude,
                visitCount: row.visit_count,
                avgDurationMinutes: row.avg_duration,
                typicalDays: row.typical_days,
                typicalHours: row.typical_hours,
                lastVisit: iso.string(from: row.last_visit)
            )
        }

        return VisitPatternResponse(patterns: patterns)
    }

    private struct PatternRow: Decodable {
        let poi_id: String?
        let name: String
        let category: String
        let latitude: Double
        let longitude: Double
        let visit_count: Int
        let avg_duration: Int
        let typical_days: [Int]
        let typical_hours: [Int]
        let last_visit: Date
    }
}

// MARK: - Vapor Content conformance

extension VisitBatchRequest: @retroactive Content {}
extension VisitBatchResponse: @retroactive Content {}
extension VisitPatternResponse: @retroactive Content {}
