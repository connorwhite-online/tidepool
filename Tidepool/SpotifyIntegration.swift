import Foundation
import AuthenticationServices
import CommonCrypto
import SwiftUI

// MARK: - Spotify Data Models

struct SpotifyCredentials: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date

    var isExpired: Bool {
        Date() >= expiresAt
    }

    var needsRefresh: Bool {
        // Refresh 5 minutes before expiry
        Date() >= expiresAt.addingTimeInterval(-300)
    }
}

struct SpotifyTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

struct SpotifyImage: Codable {
    let url: String
    let width: Int?
    let height: Int?
}

struct SpotifyArtist: Codable, Identifiable {
    let id: String
    let name: String
    let genres: [String]
    let popularity: Int
    let images: [SpotifyImage]?

    var smallestImageURL: String? {
        images?.min(by: { ($0.width ?? 0) < ($1.width ?? 0) })?.url
    }
}

struct SpotifyAlbum: Codable {
    let id: String
    let name: String
    let genres: [String]?
}

struct SpotifyTrackArtist: Codable, Identifiable {
    let id: String
    let name: String
}

struct SpotifyTrack: Codable, Identifiable {
    let id: String
    let name: String
    let artists: [SpotifyTrackArtist]
    let album: SpotifyAlbum?
    let popularity: Int
}

struct SpotifyTopItemsResponse<T: Codable>: Codable {
    let items: [T]
    let total: Int
    let limit: Int
    let offset: Int
}

enum SpotifyTimeRange: String, CaseIterable {
    case shortTerm = "short_term"   // ~4 weeks
    case mediumTerm = "medium_term" // ~6 months
    case longTerm = "long_term"     // Several years

    var displayName: String {
        switch self {
        case .shortTerm: return "Recent"
        case .mediumTerm: return "Last 6 months"
        case .longTerm: return "All time"
        }
    }
}

struct SpotifyUserData: Codable {
    let topArtists: [SpotifyArtist]
    let topTracks: [SpotifyTrack]
    let fetchedAt: Date
    let timeRange: String
}

// MARK: - Spotify Errors

enum SpotifyAuthError: LocalizedError {
    case invalidURL
    case noCallback
    case noAuthorizationCode
    case tokenExchangeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid authorization URL"
        case .noCallback: return "No callback received"
        case .noAuthorizationCode: return "No authorization code in callback"
        case .tokenExchangeFailed: return "Failed to exchange code for tokens"
        case .cancelled: return "Authentication was cancelled"
        }
    }
}

enum SpotifyAPIError: LocalizedError {
    case invalidResponse
    case rateLimited
    case serverError(Int)
    case noCredentials
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from Spotify"
        case .rateLimited: return "Rate limited by Spotify"
        case .serverError(let code): return "Spotify server error: \(code)"
        case .noCredentials: return "No Spotify credentials found"
        case .decodingError(let message): return "Failed to decode response: \(message)"
        }
    }
}

enum SpotifyError: LocalizedError {
    case authenticationFailed(String)
    case syncFailed(String)
    case noCredentials

    var errorDescription: String? {
        switch self {
        case .authenticationFailed(let message): return "Authentication failed: \(message)"
        case .syncFailed(let message): return "Sync failed: \(message)"
        case .noCredentials: return "No Spotify credentials found"
        }
    }
}

// MARK: - Spotify Auth Manager

class SpotifyAuthManager: NSObject {
    // IMPORTANT: Replace with your actual Spotify Client ID from developer.spotify.com/dashboard
    // For development, you can also use environment variables or a config file
    private let clientID: String = {
        // Try to get from environment or use placeholder
        ProcessInfo.processInfo.environment["SPOTIFY_CLIENT_ID"] ?? "YOUR_SPOTIFY_CLIENT_ID"
    }()

    private let redirectURI = "tidepool-spotify://callback"
    private let scopes = "user-top-read user-read-recently-played"

    private var authSession: ASWebAuthenticationSession?
    private weak var presentationContext: ASWebAuthenticationPresentationContextProviding?

    func setPresentationContext(_ context: ASWebAuthenticationPresentationContextProviding) {
        self.presentationContext = context
    }

    // MARK: - PKCE Generation

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }

        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Build Authorization URL

    func buildAuthorizationURL() -> (url: URL, codeVerifier: String)? {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]

        guard let url = components.url else { return nil }
        return (url, codeVerifier)
    }

    // MARK: - Authenticate

    @MainActor
    func authenticate(presentationContext: ASWebAuthenticationPresentationContextProviding) async throws -> SpotifyCredentials {
        guard let (authURL, codeVerifier) = buildAuthorizationURL() else {
            throw SpotifyAuthError.invalidURL
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "tidepool-spotify"
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError {
                    if error.code == .canceledLogin {
                        continuation.resume(throwing: SpotifyAuthError.cancelled)
                    } else {
                        continuation.resume(throwing: error)
                    }
                } else if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.noCallback)
                }
            }

            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false

            self.authSession = session

            if !session.start() {
                continuation.resume(throwing: SpotifyAuthError.invalidURL)
            }
        }

        // Extract authorization code from callback
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.noAuthorizationCode
        }

        // Exchange code for tokens
        return try await exchangeCodeForTokens(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - Token Exchange

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> SpotifyCredentials {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyAuthError.tokenExchangeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(codeVerifier)"
        ].joined(separator: "&")

        request.httpBody = bodyParams.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw SpotifyAuthError.tokenExchangeFailed
        }

        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

        return SpotifyCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    // MARK: - Token Refresh

    func refreshAccessToken(refreshToken: String) async throws -> SpotifyCredentials {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else {
            throw SpotifyAuthError.tokenExchangeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientID)"
        ].joined(separator: "&")

        request.httpBody = bodyParams.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

        return SpotifyCredentials(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }
}

// MARK: - Spotify API Client

class SpotifyAPIClient {
    private let baseURL = "https://api.spotify.com/v1"
    private let keychainManager: KeychainManager
    private let authManager: SpotifyAuthManager

    init(keychainManager: KeychainManager = .shared, authManager: SpotifyAuthManager) {
        self.keychainManager = keychainManager
        self.authManager = authManager
    }

    // MARK: - Get Top Artists

    func getTopArtists(timeRange: SpotifyTimeRange = .mediumTerm, limit: Int = 50) async throws -> [SpotifyArtist] {
        let endpoint = "/me/top/artists"
        let queryItems = [
            URLQueryItem(name: "time_range", value: timeRange.rawValue),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let response: SpotifyTopItemsResponse<SpotifyArtist> = try await makeRequest(
            endpoint: endpoint,
            queryItems: queryItems
        )
        return response.items
    }

    // MARK: - Get Top Tracks

    func getTopTracks(timeRange: SpotifyTimeRange = .mediumTerm, limit: Int = 50) async throws -> [SpotifyTrack] {
        let endpoint = "/me/top/tracks"
        let queryItems = [
            URLQueryItem(name: "time_range", value: timeRange.rawValue),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        let response: SpotifyTopItemsResponse<SpotifyTrack> = try await makeRequest(
            endpoint: endpoint,
            queryItems: queryItems
        )
        return response.items
    }

    // MARK: - Generic Request with Auto Token Refresh

    private func makeRequest<T: Decodable>(endpoint: String, queryItems: [URLQueryItem] = []) async throws -> T {
        // Get credentials from Keychain
        var credentials: SpotifyCredentials
        do {
            credentials = try keychainManager.load(SpotifyCredentials.self, for: .spotifyCredentials)
        } catch {
            throw SpotifyAPIError.noCredentials
        }

        // Refresh if needed
        if credentials.needsRefresh {
            credentials = try await authManager.refreshAccessToken(refreshToken: credentials.refreshToken)
            try keychainManager.save(credentials, for: .spotifyCredentials)
        }

        // Build request
        var components = URLComponents(string: baseURL + endpoint)!
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw SpotifyAPIError.decodingError(error.localizedDescription)
            }
        case 401:
            // Token expired mid-request, refresh and retry once
            credentials = try await authManager.refreshAccessToken(refreshToken: credentials.refreshToken)
            try keychainManager.save(credentials, for: .spotifyCredentials)
            return try await makeRequest(endpoint: endpoint, queryItems: queryItems)
        case 429:
            throw SpotifyAPIError.rateLimited
        default:
            throw SpotifyAPIError.serverError(httpResponse.statusCode)
        }
    }
}

// MARK: - Spotify Integration Manager

@MainActor
class SpotifyIntegrationManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    // Published state
    @Published var isConnected: Bool = false
    @Published var isSyncing: Bool = false
    @Published var topArtists: [SpotifyArtist] = []
    @Published var topTracks: [SpotifyTrack] = []
    @Published var lastSynced: Date?
    @Published var error: SpotifyError?
    @Published var selectedTimeRange: SpotifyTimeRange = .mediumTerm

    // Private dependencies
    private let authManager = SpotifyAuthManager()
    private lazy var apiClient = SpotifyAPIClient(keychainManager: keychainManager, authManager: authManager)
    private let keychainManager = KeychainManager.shared
    private let userDefaults = UserDefaults.standard

    // Keys
    private let lastSyncedKey = "spotify_last_synced"
    private let cachedDataKey = "spotify_cached_data"

    override init() {
        super.init()

        loadCachedData()
        checkConnectionStatus()
    }

    // MARK: - Public Methods

    func authenticate() async {
        do {
            let credentials = try await authManager.authenticate(presentationContext: self)
            try keychainManager.save(credentials, for: .spotifyCredentials)
            isConnected = true
            error = nil
            await refreshData()
            HapticFeedbackManager.shared.notification(.success)
        } catch let authError as SpotifyAuthError {
            if case .cancelled = authError {
                // User cancelled, don't show error
                return
            }
            self.error = .authenticationFailed(authError.localizedDescription)
            HapticFeedbackManager.shared.notification(.error)
        } catch {
            self.error = .authenticationFailed(error.localizedDescription)
            HapticFeedbackManager.shared.notification(.error)
        }
    }

    func disconnect() {
        do {
            try keychainManager.delete(for: .spotifyCredentials)
        } catch {
            // Ignore deletion errors
        }

        isConnected = false
        topArtists = []
        topTracks = []
        lastSynced = nil
        error = nil
        clearCachedData()

        HapticFeedbackManager.shared.impact(.light)
    }

    func refreshData() async {
        guard isConnected else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            async let artists = apiClient.getTopArtists(timeRange: selectedTimeRange, limit: 50)
            async let tracks = apiClient.getTopTracks(timeRange: selectedTimeRange, limit: 50)

            topArtists = try await artists
            topTracks = try await tracks
            lastSynced = Date()
            error = nil

            saveCachedData()
            userDefaults.set(lastSynced, forKey: lastSyncedKey)

            HapticFeedbackManager.shared.notification(.success)
        } catch {
            self.error = .syncFailed(error.localizedDescription)
            HapticFeedbackManager.shared.notification(.error)
        }
    }

    func getSummary() -> String? {
        guard !topArtists.isEmpty else { return nil }

        let topGenres = extractTopGenres(limit: 3)
        if topGenres.isEmpty {
            return "\(topArtists.count) artists"
        }
        return topGenres.joined(separator: ", ")
    }

    // MARK: - Interest Tags for InterestVectorManager

    func getInterestTags() -> [String: Int] {
        var tagCounts: [String: Int] = [:]

        // Process top artists
        for (index, artist) in topArtists.enumerated() {
            // Weight by ranking (top artists get higher weight)
            let positionWeight = max(1, 10 - index / 5)

            // Add genres as tags
            for genre in artist.genres {
                let mappedTags = MusicGenreMapper.mapGenreToTags(genre)
                for tag in mappedTags {
                    tagCounts[tag, default: 0] += positionWeight
                }
            }

            // Add artist tag (top 20 only to avoid tag explosion)
            if index < 20 {
                let artistTag = MusicGenreMapper.generateArtistTag(artist.name)
                tagCounts[artistTag, default: 0] += positionWeight
            }

            // Add popularity-based tags
            if artist.popularity > 70 {
                tagCounts["popular", default: 0] += 1
                tagCounts["mainstream", default: 0] += 1
            } else if artist.popularity < 30 {
                tagCounts["indie", default: 0] += 1
                tagCounts["underground", default: 0] += 1
            }
        }

        // Process top tracks for additional genre coverage
        for (index, track) in topTracks.enumerated() {
            let positionWeight = max(1, 5 - index / 10)

            // Add track artist names as potential matches
            for artist in track.artists {
                if index < 30 {
                    let artistTag = MusicGenreMapper.generateArtistTag(artist.name)
                    tagCounts[artistTag, default: 0] += positionWeight
                }
            }
        }

        // Always add base music tag if we have data
        if !topArtists.isEmpty || !topTracks.isEmpty {
            tagCounts["music", default: 0] += 5
        }

        return tagCounts
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }

    // MARK: - Private Methods

    private func checkConnectionStatus() {
        do {
            let credentials: SpotifyCredentials = try keychainManager.load(SpotifyCredentials.self, for: .spotifyCredentials)
            isConnected = !credentials.isExpired || !credentials.refreshToken.isEmpty
        } catch {
            isConnected = false
        }
    }

    private func extractTopGenres(limit: Int) -> [String] {
        var genreCounts: [String: Int] = [:]
        for artist in topArtists {
            for genre in artist.genres {
                genreCounts[genre, default: 0] += 1
            }
        }
        return genreCounts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { $0.key.capitalized }
    }

    private func saveCachedData() {
        let data = SpotifyUserData(
            topArtists: topArtists,
            topTracks: topTracks,
            fetchedAt: Date(),
            timeRange: selectedTimeRange.rawValue
        )
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: cachedDataKey)
        }
    }

    private func loadCachedData() {
        guard let data = userDefaults.data(forKey: cachedDataKey),
              let decoded = try? JSONDecoder().decode(SpotifyUserData.self, from: data) else {
            return
        }
        topArtists = decoded.topArtists
        topTracks = decoded.topTracks
        lastSynced = decoded.fetchedAt
    }

    private func clearCachedData() {
        userDefaults.removeObject(forKey: cachedDataKey)
        userDefaults.removeObject(forKey: lastSyncedKey)
    }
}
