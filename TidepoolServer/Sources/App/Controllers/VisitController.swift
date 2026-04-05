import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct VisitController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("batch", use: batchUpload)
        routes.get("patterns", use: patterns)
    }

    /// Accept a batch of visit reports, deduplicate, and insert.
    func batchUpload(req: Request) async throws -> VisitBatchResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(VisitBatchRequest.self)

        let iso = ISO8601DateFormatter()
        var accepted = 0
        var duplicates = 0

        for report in body.visits {
            guard let arrivedDate = iso.date(from: report.arrivedAt),
                  let departedDate = iso.date(from: report.departedAt) else { continue }

            // Deduplicate: check for existing visit within 5min window at same location
            let existingCount = try await Visit.query(on: req.db)
                .filter(\.$device.$id == payload.deviceID)
                .filter(\.$latitude >= report.latitude - 0.0005)
                .filter(\.$latitude <= report.latitude + 0.0005)
                .filter(\.$longitude >= report.longitude - 0.0005)
                .filter(\.$longitude <= report.longitude + 0.0005)
                .filter(\.$arrivedAt >= arrivedDate.addingTimeInterval(-300))
                .filter(\.$arrivedAt <= arrivedDate.addingTimeInterval(300))
                .count()

            if existingCount > 0 {
                duplicates += 1
                continue
            }

            let visit = Visit()
            visit.$device.id = payload.deviceID
            visit.poiID = report.poiId
            visit.yelpID = report.yelpId
            visit.name = report.name
            visit.category = report.category.rawValue
            visit.latitude = report.latitude
            visit.longitude = report.longitude
            visit.arrivedAt = arrivedDate
            visit.departedAt = departedDate
            visit.dayOfWeek = report.dayOfWeek
            visit.hourOfDay = report.hourOfDay
            visit.durationMinutes = report.durationMinutes
            visit.confidence = report.confidence
            visit.source = report.source
            visit.createdAt = Date()

            try await visit.save(on: req.db)
            accepted += 1
        }

        return VisitBatchResponse(accepted: accepted, duplicates: duplicates)
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
