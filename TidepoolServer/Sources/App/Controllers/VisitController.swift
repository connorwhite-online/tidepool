import Vapor
import Fluent
import SQLKit
import TidepoolShared

struct VisitController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.on(.POST, "batch", body: .collect(maxSize: "10mb"), use: batchUpload)
        routes.get("patterns", use: patterns)
        routes.get("recent", use: recent)
        routes.put(":visitID", use: updateVisit)
        routes.delete(":visitID", use: deleteVisit)
    }

    /// Accept a batch of visit reports, deduplicate per-row, and insert
    /// non-duplicates. Spatial+temporal proximity dedup — same device,
    /// ~50m, ±5min.
    ///
    /// We fetch all existing visits in the batch's combined arrival window
    /// in a single query rather than running a COUNT per row, then dedup
    /// in memory. For a 50-visit batch this collapses 50 round-trips to
    /// Postgres into one.
    func batchUpload(req: Request) async throws -> VisitBatchResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let body = try req.content.decode(VisitBatchRequest.self)

        let iso = iso8601Formatter
        let latEpsilon = 0.0005
        let lonEpsilon = 0.0005
        let timeWindow: TimeInterval = 300

        // Pre-parse arrival/departure dates and bail any rows with bad ISO strings.
        struct Parsed {
            let report: VisitReport
            let arrived: Date
            let departed: Date
        }
        var parsed: [Parsed] = []
        parsed.reserveCapacity(body.visits.count)
        var skipped = 0
        for report in body.visits {
            guard let a = iso.date(from: report.arrivedAt),
                  let d = iso.date(from: report.departedAt) else {
                skipped += 1
                continue
            }
            parsed.append(Parsed(report: report, arrived: a, departed: d))
        }

        // Single query: every existing visit for this device whose arrival
        // falls within timeWindow of any incoming row.
        var existing: [Visit] = []
        if let firstArrival = parsed.map(\.arrived).min(),
           let lastArrival = parsed.map(\.arrived).max() {
            existing = try await Visit.query(on: req.db)
                .filter(\.$device.$id == payload.deviceID)
                .filter(\.$arrivedAt >= firstArrival.addingTimeInterval(-timeWindow))
                .filter(\.$arrivedAt <= lastArrival.addingTimeInterval(timeWindow))
                .all()
        }

        // In-memory dedup against the prefetched set + the rows we've already
        // decided to accept in this batch (so two identical rows in one batch
        // collapse correctly).
        var toInsert: [Visit] = []
        toInsert.reserveCapacity(parsed.count)
        var duplicates = 0

        func isDuplicate(_ p: Parsed) -> Bool {
            let candidates = existing.lazy + toInsert.lazy.map { v -> Visit in v }
            for c in candidates {
                if abs(c.latitude - p.report.latitude) <= latEpsilon,
                   abs(c.longitude - p.report.longitude) <= lonEpsilon,
                   abs(c.arrivedAt.timeIntervalSince(p.arrived)) <= timeWindow {
                    return true
                }
            }
            return false
        }

        for p in parsed {
            if isDuplicate(p) {
                duplicates += 1
                continue
            }
            let visit = Visit()
            visit.$device.id = payload.deviceID
            visit.poiID = p.report.poiId
            visit.yelpID = p.report.yelpId
            visit.name = p.report.name
            visit.category = p.report.category.rawValue
            visit.latitude = p.report.latitude
            visit.longitude = p.report.longitude
            visit.arrivedAt = p.arrived
            visit.departedAt = p.departed
            visit.dayOfWeek = p.report.dayOfWeek
            visit.hourOfDay = p.report.hourOfDay
            visit.durationMinutes = p.report.durationMinutes
            visit.confidence = p.report.confidence
            visit.source = p.report.source
            visit.createdAt = Date()
            toInsert.append(visit)
        }

        var accepted = 0
        if !toInsert.isEmpty {
            do {
                try await toInsert.create(on: req.db)
                accepted = toInsert.count
            } catch {
                // Fall back to per-row inserts so one bad row can't 500 the batch.
                req.logger.warning("visits/batch: bulk insert failed (\(error)); falling back to per-row")
                for visit in toInsert {
                    do {
                        try await visit.save(on: req.db)
                        accepted += 1
                    } catch {
                        req.logger.warning("visits/batch: skipping '\(visit.name)' at (\(visit.latitude), \(visit.longitude)): \(error)")
                        skipped += 1
                    }
                }
            }
        }

        if skipped > 0 {
            req.logger.info("visits/batch: accepted=\(accepted) duplicates=\(duplicates) skipped=\(skipped)")
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

        let iso = iso8601Formatter
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

    // MARK: - Recent Visits (chronological)

    /// GET /v1/visits/recent?limit=50 — Individual visits, newest first.
    func recent(req: Request) async throws -> [VisitReport] {
        let payload = try req.auth.require(DevicePayload.self)
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 50

        let visits = try await Visit.query(on: req.db)
            .filter(\.$device.$id == payload.deviceID)
            .sort(\.$arrivedAt, .descending)
            .limit(min(limit, 200))
            .all()

        let iso = iso8601Formatter
        return visits.map { v in
            VisitReport(
                id: v.id?.uuidString,
                poiId: v.poiID, yelpId: v.yelpID, name: v.name,
                category: PlaceCategory(rawValue: v.category) ?? .other,
                latitude: v.latitude, longitude: v.longitude,
                arrivedAt: iso.string(from: v.arrivedAt),
                departedAt: iso.string(from: v.departedAt),
                dayOfWeek: v.dayOfWeek, hourOfDay: v.hourOfDay,
                durationMinutes: v.durationMinutes,
                confidence: v.confidence, source: v.source
            )
        }
    }

    // MARK: - Update Visit

    /// PUT /v1/visits/:visitID — replace the mutable fields of a visit.
    /// Caller-supplied id, device_id, and created_at are ignored; everything
    /// else is overwritten. Returns the updated VisitReport.
    func updateVisit(req: Request) async throws -> VisitReport {
        let payload = try req.auth.require(DevicePayload.self)
        guard let idStr = req.parameters.get("visitID"),
              let id = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid visit ID")
        }
        guard let visit = try await Visit.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        guard visit.$device.id == payload.deviceID else {
            throw Abort(.forbidden)
        }

        let body = try req.content.decode(VisitReport.self)
        let iso = iso8601Formatter
        guard let arrivedDate = iso.date(from: body.arrivedAt),
              let departedDate = iso.date(from: body.departedAt) else {
            throw Abort(.badRequest, reason: "Invalid arrived_at or departed_at")
        }

        visit.poiID = body.poiId
        visit.yelpID = body.yelpId
        visit.name = body.name
        visit.category = body.category.rawValue
        visit.latitude = body.latitude
        visit.longitude = body.longitude
        visit.arrivedAt = arrivedDate
        visit.departedAt = departedDate
        visit.dayOfWeek = body.dayOfWeek
        visit.hourOfDay = body.hourOfDay
        visit.durationMinutes = body.durationMinutes
        visit.confidence = body.confidence
        visit.source = body.source

        try await visit.save(on: req.db)

        return VisitReport(
            id: visit.id?.uuidString,
            poiId: visit.poiID, yelpId: visit.yelpID, name: visit.name,
            category: PlaceCategory(rawValue: visit.category) ?? .other,
            latitude: visit.latitude, longitude: visit.longitude,
            arrivedAt: iso.string(from: visit.arrivedAt),
            departedAt: iso.string(from: visit.departedAt),
            dayOfWeek: visit.dayOfWeek, hourOfDay: visit.hourOfDay,
            durationMinutes: visit.durationMinutes,
            confidence: visit.confidence, source: visit.source
        )
    }

    // MARK: - Delete Visit

    /// DELETE /v1/visits/:visitID
    func deleteVisit(req: Request) async throws -> HTTPStatus {
        let payload = try req.auth.require(DevicePayload.self)
        guard let idStr = req.parameters.get("visitID"),
              let id = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid visit ID")
        }
        guard let visit = try await Visit.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        guard visit.$device.id == payload.deviceID else {
            throw Abort(.forbidden)
        }
        try await visit.delete(on: req.db)
        return .noContent
    }
}

// MARK: - Vapor Content conformance

extension VisitBatchRequest: @retroactive Content {}
extension VisitBatchResponse: @retroactive Content {}
extension VisitPatternResponse: @retroactive Content {}
extension VisitReport: @retroactive Content {}
