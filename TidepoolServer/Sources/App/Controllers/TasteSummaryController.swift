import Vapor
import Fluent
import SQLKit
@preconcurrency import Redis
import TidepoolShared

struct TasteSummaryController: RouteCollection {
    private let cacheTTLSeconds = 3600 // 1 hour

    func boot(routes: RoutesBuilder) throws {
        routes.get("taste-summary", use: tasteSummary)
    }

    /// Generate a natural-language taste summary using Claude Haiku.
    /// Cached in Redis for 1 hour per device.
    func tasteSummary(req: Request) async throws -> TasteSummaryResponse {
        let payload = try req.auth.require(DevicePayload.self)
        let deviceIDStr = payload.deviceID.uuidString

        // Check Redis cache
        let cacheKey = RedisKey("taste_summary:\(deviceIDStr)")
        let cached = try await req.redis.get(cacheKey, as: String.self).get()
        if let cached, let data = cached.data(using: .utf8),
           let response = try? JSONDecoder().decode(TasteSummaryResponse.self, from: data) {
            return response
        }

        // Load interest vector
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database required")
        }

        let vectorRows = try await sql.raw(SQLQueryString("""
            SELECT interest_vector::text as interest_vector
            FROM device_profiles WHERE device_id = '\(unsafeRaw: deviceIDStr)'::uuid
            """)).all(decoding: VectorRow.self)

        guard let vectorStr = vectorRows.first?.interest_vector else {
            throw Abort(.notFound, reason: "No profile vector found")
        }

        let vector = DeviceProfile.stringToVector(vectorStr)

        // Get top interests from the vector
        let topInterests = InterestVocabulary.topTags(from: vector, count: 10)

        // Load favorites for context
        let favorites = try await Favorite.query(on: req.db)
            .filter(\.$device.$id == payload.deviceID)
            .all()

        let favNames = favorites.prefix(10).map { $0.name }

        // Call Claude Haiku
        guard let apiKey = Environment.get("ANTHROPIC_API_KEY") else {
            // Fallback: generate a simple summary without Claude
            let summary = "You enjoy \(topInterests.prefix(3).joined(separator: ", ")) spots."
            let response = TasteSummaryResponse(
                summary: summary,
                topInterests: topInterests,
                generatedAt: ISO8601DateFormatter().string(from: Date())
            )
            return response
        }

        let prompt = buildPrompt(topInterests: topInterests, favoriteNames: favNames)
        let summary = try await callClaude(apiKey: apiKey, prompt: prompt, on: req)

        let response = TasteSummaryResponse(
            summary: summary,
            topInterests: topInterests,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Cache in Redis
        if let data = try? JSONEncoder().encode(response),
           let json = String(data: data, encoding: .utf8) {
            _ = try? await req.redis.set(cacheKey, to: json).get()
            _ = try? await req.redis.send(command: "EXPIRE", with: [
                .init(from: cacheKey.rawValue),
                .init(from: String(cacheTTLSeconds))
            ]).get()
        }

        return response
    }

    // MARK: - Claude API

    private func buildPrompt(topInterests: [String], favoriteNames: [String]) -> String {
        var parts = ["A user's top interests are: \(topInterests.joined(separator: ", "))."]
        if !favoriteNames.isEmpty {
            parts.append("Their favorite places include: \(favoriteNames.joined(separator: ", ")).")
        }
        parts.append("Write a 2-3 sentence taste profile summary for this person. Be warm, specific, and conversational. Don't use bullet points or lists. Focus on the vibe they're drawn to.")
        return parts.joined(separator: " ")
    }

    private func callClaude(apiKey: String, prompt: String, on req: Request) async throws -> String {
        let uri = URI(string: "https://api.anthropic.com/v1/messages")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 200,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var headers = HTTPHeaders()
        headers.add(name: "x-api-key", value: apiKey)
        headers.add(name: "anthropic-version", value: "2023-06-01")
        headers.add(name: "content-type", value: "application/json")

        let clientResponse = try await req.client.post(uri, headers: headers) { clientReq in
            clientReq.body = .init(data: jsonData)
        }

        guard let responseBody = clientResponse.body else {
            throw Abort(.badGateway, reason: "Empty response from Claude API")
        }

        let data = Data(buffer: responseBody)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw Abort(.badGateway, reason: "Unexpected Claude API response format")
        }

        return text
    }

    private struct VectorRow: Decodable {
        let interest_vector: String
    }
}

extension TasteSummaryResponse: @retroactive Content {}
