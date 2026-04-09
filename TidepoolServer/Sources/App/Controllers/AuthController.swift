import Vapor
import JWT
import Fluent
import TidepoolShared

struct AuthController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("attest", use: attest)
        routes.post("debug", use: debugAuth)
    }

    // MARK: - App Attest (Production)

    /// Validates an App Attest attestation and issues a JWT.
    /// Full attestation validation (certificate chain verification) is a Phase 1.5 enhancement.
    /// For now, we trust the attestation object and register the key ID.
    func attest(req: Request) async throws -> Response {
        let body = try req.content.decode(AttestRequest.self)

        // Check for replay
        if let existing = try await Device.query(on: req.db)
            .filter(\.$keyID == body.keyID)
            .first() {
            // Device already attested — re-issue token
            existing.lastSeenAt = Date()
            existing.appVersion = body.appVersion
            try await existing.save(on: req.db)
            let response = try issueToken(for: existing, on: req)
            return try await response.encodeResponse(for: req)
        }

        // Register new device
        let device = Device(
            keyID: body.keyID,
            attestationHash: body.attestationObject.sha256Hash,
            appVersion: body.appVersion
        )
        try await device.save(on: req.db)

        let response = try issueToken(for: device, on: req)
        return try await response.encodeResponse(for: req)
    }

    // MARK: - Debug Auth (Development Only)

    struct DebugAuthRequest: Content {
        let deviceName: String

        enum CodingKeys: String, CodingKey {
            case deviceName = "device_name"
        }
    }

    /// Issues a JWT for a synthetic device. Only available in development.
    func debugAuth(req: Request) async throws -> Response {
        guard req.application.environment != .production else {
            throw Abort(.notFound)
        }

        let body = try req.content.decode(DebugAuthRequest.self)
        let syntheticKeyID = "debug-\(body.deviceName)-\(UUID().uuidString.prefix(8))"

        // Find or create debug device
        if let existing = try await Device.query(on: req.db)
            .filter(\.$keyID, .custom("LIKE"), "debug-\(body.deviceName)-%")
            .first() {
            existing.lastSeenAt = Date()
            try await existing.save(on: req.db)
            let response = try issueToken(for: existing, on: req)
            return try await response.encodeResponse(for: req)
        }

        let device = Device(
            keyID: syntheticKeyID,
            appVersion: "debug"
        )
        try await device.save(on: req.db)

        let response = try issueToken(for: device, on: req)
        return try await response.encodeResponse(for: req)
    }

    // MARK: - Token Issuance

    private func issueToken(for device: Device, on req: Request) throws -> AuthResponse {
        let expiresIn = 60 * 60 * 24 * 7 // 7 days
        let payload = DevicePayload(
            sub: .init(value: device.id!.uuidString),
            iat: .init(value: Date()),
            exp: .init(value: Date().addingTimeInterval(TimeInterval(expiresIn)))
        )

        let token = try req.jwt.sign(payload)

        return AuthResponse(
            token: token,
            expiresIn: expiresIn,
            deviceID: device.id!.uuidString
        )
    }
}

// MARK: - Vapor Content conformance for TidepoolShared types

extension AttestRequest: @retroactive Content {}
extension AuthResponse: @retroactive Content {}

// MARK: - Helpers

extension String {
    var sha256Hash: String {
        var hasher = Hasher()
        hasher.combine(self)
        return String(format: "%016x", hasher.finalize())
    }
}
