import Foundation
import TidepoolShared

// MARK: - Backend Errors

enum BackendError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with backend"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code, let message):
            return "Server error \(code): \(message ?? "Unknown")"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Backend Client

@MainActor
class BackendClient: ObservableObject {
    static let shared = BackendClient()

    @Published var isAuthenticated = false
    @Published var deviceID: String?

    private let keychainManager = KeychainManager.shared

    #if DEBUG
    private let baseURL = "http://192.168.86.25:8080"
    #else
    private let baseURL = "https://tidepool-production.up.railway.app"
    #endif

    private var token: String?

    init() {
        loadCredentials()
    }

    // MARK: - Credential Management

    private func loadCredentials() {
        guard let credentials = try? keychainManager.load(BackendCredentials.self, for: .backendCredentials),
              !credentials.isExpired else {
            isAuthenticated = false
            token = nil
            deviceID = nil
            return
        }
        token = credentials.token
        deviceID = credentials.deviceID
        isAuthenticated = true
    }

    private func storeCredentials(_ response: AuthResponse) throws {
        let credentials = BackendCredentials(
            token: response.token,
            deviceID: response.deviceID,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
        try keychainManager.save(credentials, for: .backendCredentials)
        token = credentials.token
        deviceID = credentials.deviceID
        isAuthenticated = true
    }

    func logout() {
        try? keychainManager.delete(for: .backendCredentials)
        token = nil
        deviceID = nil
        isAuthenticated = false
    }

    // MARK: - Auth

    #if DEBUG
    /// Debug authentication for simulator. Creates a synthetic device on the server.
    func debugAuthenticate(deviceName: String = "simulator") async throws {
        struct DebugRequest: Encodable {
            let deviceName: String
            enum CodingKeys: String, CodingKey {
                case deviceName = "device_name"
            }
        }

        let response: AuthResponse = try await request(
            method: "POST",
            path: "/v1/auth/debug",
            body: DebugRequest(deviceName: deviceName),
            authenticated: false
        )
        try storeCredentials(response)
    }
    #endif

    /// Authenticate using App Attest. Call after generating attestation via DCAppAttestService.
    func authenticate(attestationObject: String, keyID: String, appVersion: String) async throws {
        let body = AttestRequest(
            attestationObject: attestationObject,
            keyID: keyID,
            appVersion: appVersion
        )
        let response: AuthResponse = try await request(
            method: "POST",
            path: "/v1/auth/attest",
            body: body,
            authenticated: false
        )
        try storeCredentials(response)
    }

    // MARK: - Profile

    func uploadVector(_ body: ProfileVectorRequest) async throws -> ProfileVectorResponse {
        try await request(method: "PUT", path: "/v1/profile/vector", body: body)
    }

    func getVector() async throws -> ProfileVectorResponse {
        try await request(method: "GET", path: "/v1/profile/vector")
    }

    // MARK: - Taste Summary

    func getTasteSummary() async throws -> TasteSummaryResponse {
        try await request(method: "GET", path: "/v1/profile/taste-summary")
    }

    // MARK: - Visits

    func uploadVisits(_ body: VisitBatchRequest) async throws -> VisitBatchResponse {
        try await request(method: "POST", path: "/v1/visits/batch", body: body)
    }

    func getVisitPatterns() async throws -> VisitPatternResponse {
        try await request(method: "GET", path: "/v1/visits/patterns")
    }

    // MARK: - Aligned Heat & Recommendations

    func fetchAlignedHeat(_ body: AlignedHeatRequest) async throws -> HeatTileResponse {
        try await request(method: "POST", path: "/v1/tiles/aligned-heat", body: body)
    }

    func getRecommendations(_ body: RecommendationRequest) async throws -> RecommendationResponse {
        try await request(method: "POST", path: "/v1/recommendations", body: body)
    }

    // MARK: - Multi-Vector Profile

    func uploadMultiVector(_ body: MultiVectorRequest) async throws -> ProfileVectorResponse {
        try await request(method: "PUT", path: "/v1/profile/vectors", body: body)
    }

    // MARK: - Presence

    func reportPresence(_ report: PresenceReport) async throws -> PresenceResponse {
        try await request(method: "POST", path: "/v1/presence/report", body: report)
    }

    // MARK: - Heat Tiles

    func fetchHeatTiles(_ body: HeatTileRequest) async throws -> HeatTileResponse {
        try await request(method: "POST", path: "/v1/tiles/heat", body: body)
    }

    // MARK: - Places

    func searchPlaces(_ body: PlaceSearchRequest) async throws -> PlaceSearchResponse {
        try await request(method: "POST", path: "/v1/search/places", body: body)
    }

    func getPlaceDetail(yelpID: String) async throws -> PlaceDetail {
        try await request(method: "GET", path: "/v1/places/\(yelpID)")
    }

    func matchPlace(name: String, lat: Double, lng: Double) async throws -> PlaceDetail {
        let query = "name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&lat=\(lat)&lng=\(lng)"
        return try await request(method: "GET", path: "/v1/places/match?\(query)")
    }

    // MARK: - Favorites

    func addFavorite(_ body: FavoriteRequest) async throws -> FavoriteResponse {
        try await request(method: "POST", path: "/v1/favorites", body: body)
    }

    func getFavorites() async throws -> [FavoriteResponse] {
        try await request(method: "GET", path: "/v1/favorites")
    }

    func deleteFavorite(id: String) async throws {
        let _: EmptyResponse = try await request(method: "DELETE", path: "/v1/favorites/\(id)")
    }

    // MARK: - Generic Request

    private func request<Res: Decodable>(
        method: String,
        path: String,
        body: (some Encodable)? = nil as String?,
        authenticated: Bool = true
    ) async throws -> Res {
        if authenticated {
            guard let token else {
                throw BackendError.notAuthenticated
            }
            // Check if token is expired and reload
            if let creds = try? keychainManager.load(BackendCredentials.self, for: .backendCredentials),
               creds.isExpired {
                logout()
                throw BackendError.notAuthenticated
            }
            _ = token // suppress warning; used below in request building
        }

        guard let url = URL(string: baseURL + path) else {
            throw BackendError.invalidResponse
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method

        if authenticated, let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw BackendError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            // Handle empty responses (e.g., DELETE)
            if data.isEmpty, let empty = EmptyResponse() as? Res {
                return empty
            }
            do {
                return try JSONDecoder().decode(Res.self, from: data)
            } catch {
                throw BackendError.decodingError(error)
            }
        case 401:
            logout()
            throw BackendError.notAuthenticated
        default:
            let message = String(data: data, encoding: .utf8)
            throw BackendError.serverError(httpResponse.statusCode, message)
        }
    }
}

// MARK: - Empty Response

struct EmptyResponse: Decodable {
    init() {}
}
