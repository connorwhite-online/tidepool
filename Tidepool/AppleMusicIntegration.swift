import Foundation
import MusicKit
import SwiftUI

// MARK: - Apple Music Data Models

struct AppleMusicTrackInfo: Codable, Identifiable {
    let id: String
    let name: String
    let artistName: String
    let albumName: String?
    let genreNames: [String]
    let playedAt: Date?
}

struct AppleMusicArtistInfo: Codable, Identifiable {
    let id: String
    let name: String
    let genres: [String]
}

struct AppleMusicUserData: Codable {
    let recentlyPlayed: [AppleMusicTrackInfo]
    let libraryArtists: [AppleMusicArtistInfo]
    let libraryGenres: [String: Int]
    let fetchedAt: Date
}

// MARK: - Apple Music Errors

enum AppleMusicError: LocalizedError {
    case notAuthorized
    case syncFailed(String)
    case noSubscription
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Apple Music access not authorized"
        case .syncFailed(let message): return "Sync failed: \(message)"
        case .noSubscription: return "Apple Music subscription required for some features"
        case .notAvailable: return "Apple Music is not available on this device"
        }
    }
}

// MARK: - Apple Music Data Fetcher

class AppleMusicDataFetcher {

    // MARK: - Fetch Recently Played

    func fetchRecentlyPlayed(limit: Int = 50) async throws -> [AppleMusicTrackInfo] {
        // Use MusicLibraryRequest for recently added songs as a proxy for recently played
        // since MusicRecentlyPlayedRequest has limited availability
        var request = MusicLibraryRequest<Song>()
        request.limit = limit
        request.sort(by: \.libraryAddedDate, ascending: false)

        let response = try await request.response()

        return response.items.map { song in
            AppleMusicTrackInfo(
                id: song.id.rawValue,
                name: song.title,
                artistName: song.artistName,
                albumName: song.albumTitle,
                genreNames: song.genreNames,
                playedAt: nil
            )
        }
    }

    // MARK: - Fetch Library Artists

    func fetchLibraryArtists(limit: Int = 100) async throws -> [AppleMusicArtistInfo] {
        var request = MusicLibraryRequest<Artist>()
        request.limit = limit

        let response = try await request.response()

        return response.items.map { artist in
            AppleMusicArtistInfo(
                id: artist.id.rawValue,
                name: artist.name,
                genres: artist.genreNames ?? []
            )
        }
    }

    // MARK: - Fetch Library Songs for Genre Aggregation

    func fetchLibrarySongs(limit: Int = 200) async throws -> [AppleMusicTrackInfo] {
        var request = MusicLibraryRequest<Song>()
        request.limit = limit

        let response = try await request.response()

        return response.items.map { song in
            AppleMusicTrackInfo(
                id: song.id.rawValue,
                name: song.title,
                artistName: song.artistName,
                albumName: song.albumTitle,
                genreNames: song.genreNames,
                playedAt: nil
            )
        }
    }

    // MARK: - Aggregate Library Genres

    func aggregateLibraryGenres() async throws -> [String: Int] {
        var genreCounts: [String: Int] = [:]

        // Fetch library songs
        let songs = try await fetchLibrarySongs(limit: 200)

        for song in songs {
            for genre in song.genreNames {
                genreCounts[genre, default: 0] += 1
            }
        }

        return genreCounts
    }
}

// MARK: - Apple Music Integration Manager

@MainActor
class AppleMusicIntegrationManager: ObservableObject {
    // Published state
    @Published var isAuthorized: Bool = false
    @Published var hasSubscription: Bool = false
    @Published var isSyncing: Bool = false
    @Published var recentlyPlayed: [AppleMusicTrackInfo] = []
    @Published var libraryArtists: [AppleMusicArtistInfo] = []
    @Published var libraryGenres: [String: Int] = [:]
    @Published var lastSynced: Date?
    @Published var error: AppleMusicError?

    // Private
    private let dataFetcher = AppleMusicDataFetcher()
    private let userDefaults = UserDefaults.standard

    // Keys
    private let lastSyncedKey = "apple_music_last_synced"
    private let cachedDataKey = "apple_music_cached_data"
    private let enabledKey = "apple_music_enabled"

    init() {
        checkAuthorizationStatus()
        loadCachedData()
    }

    // MARK: - Public Methods

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        isAuthorized = status == .authorized

        if isAuthorized {
            await checkSubscription()
            await refreshData()
            HapticFeedbackManager.shared.notification(.success)
        } else {
            error = .notAuthorized
            HapticFeedbackManager.shared.notification(.error)
        }
    }

    func disconnect() {
        // Note: Cannot programmatically revoke MusicKit authorization
        // User must do this in Settings > Privacy > Media & Apple Music
        // We'll just clear our local data and mark as disconnected
        isAuthorized = false
        recentlyPlayed = []
        libraryArtists = []
        libraryGenres = [:]
        lastSynced = nil
        error = nil
        clearCachedData()
        userDefaults.set(false, forKey: enabledKey)

        HapticFeedbackManager.shared.impact(.light)
    }

    func refreshData() async {
        guard isAuthorized else { return }

        isSyncing = true
        defer { isSyncing = false }

        do {
            // Fetch data concurrently
            async let recentTask = dataFetcher.fetchRecentlyPlayed(limit: 50)
            async let artistsTask = dataFetcher.fetchLibraryArtists(limit: 100)
            async let genresTask = dataFetcher.aggregateLibraryGenres()

            recentlyPlayed = try await recentTask
            libraryArtists = try await artistsTask
            libraryGenres = try await genresTask
            lastSynced = Date()
            error = nil

            saveCachedData()
            userDefaults.set(true, forKey: enabledKey)

            HapticFeedbackManager.shared.notification(.success)
        } catch {
            self.error = .syncFailed(error.localizedDescription)
            HapticFeedbackManager.shared.notification(.error)
        }
    }

    func getSummary() -> String? {
        let topGenres = libraryGenres
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { $0.key }

        if topGenres.isEmpty && !libraryArtists.isEmpty {
            return "\(libraryArtists.count) artists"
        }

        return topGenres.isEmpty ? nil : topGenres.joined(separator: ", ")
    }

    // MARK: - Interest Tags for InterestVectorManager

    func getInterestTags() -> [String: Int] {
        var tagCounts: [String: Int] = [:]

        // Process library genres (aggregated from songs)
        for (genre, count) in libraryGenres {
            let mappedTags = MusicGenreMapper.mapGenreToTags(genre)
            for tag in mappedTags {
                // Weight by frequency in library
                let weight = min(count, 10)
                tagCounts[tag, default: 0] += weight
            }
        }

        // Process recently played (higher weight for recency)
        var recentGenres: [String: Int] = [:]
        for track in recentlyPlayed {
            for genre in track.genreNames {
                recentGenres[genre, default: 0] += 1
            }
        }

        for (genre, count) in recentGenres {
            let mappedTags = MusicGenreMapper.mapGenreToTags(genre)
            for tag in mappedTags {
                // 2x weight for recently played
                tagCounts[tag, default: 0] += count * 2
            }
        }

        // Process library artists (top 30)
        for (index, artist) in libraryArtists.prefix(30).enumerated() {
            let positionWeight = max(1, 5 - index / 6)

            // Add artist tag
            let artistTag = MusicGenreMapper.generateArtistTag(artist.name)
            tagCounts[artistTag, default: 0] += positionWeight

            // Add artist genres
            for genre in artist.genres {
                let mappedTags = MusicGenreMapper.mapGenreToTags(genre)
                for tag in mappedTags {
                    tagCounts[tag, default: 0] += positionWeight
                }
            }
        }

        // Add recently played artist tags
        var recentArtists: Set<String> = []
        for track in recentlyPlayed.prefix(30) {
            if !recentArtists.contains(track.artistName) {
                recentArtists.insert(track.artistName)
                let artistTag = MusicGenreMapper.generateArtistTag(track.artistName)
                tagCounts[artistTag, default: 0] += 2
            }
        }

        // Always add base music tag if we have data
        if !recentlyPlayed.isEmpty || !libraryArtists.isEmpty || !libraryGenres.isEmpty {
            tagCounts["music", default: 0] += 5
        }

        return tagCounts
    }

    // MARK: - Private Methods

    private func checkAuthorizationStatus() {
        let status = MusicAuthorization.currentStatus
        isAuthorized = status == .authorized

        // Also check if user previously enabled it
        let wasEnabled = userDefaults.bool(forKey: enabledKey)

        if isAuthorized && wasEnabled {
            Task {
                await checkSubscription()
            }
        } else if !isAuthorized {
            // Clear enabled flag if not authorized
            userDefaults.set(false, forKey: enabledKey)
        }
    }

    private func checkSubscription() async {
        do {
            let subscription = try await MusicSubscription.current
            hasSubscription = subscription.canPlayCatalogContent
        } catch {
            hasSubscription = false
        }
    }

    private func saveCachedData() {
        let data = AppleMusicUserData(
            recentlyPlayed: recentlyPlayed,
            libraryArtists: libraryArtists,
            libraryGenres: libraryGenres,
            fetchedAt: Date()
        )
        if let encoded = try? JSONEncoder().encode(data) {
            userDefaults.set(encoded, forKey: cachedDataKey)
        }
        userDefaults.set(lastSynced, forKey: lastSyncedKey)
    }

    private func loadCachedData() {
        guard let data = userDefaults.data(forKey: cachedDataKey),
              let decoded = try? JSONDecoder().decode(AppleMusicUserData.self, from: data) else {
            return
        }
        recentlyPlayed = decoded.recentlyPlayed
        libraryArtists = decoded.libraryArtists
        libraryGenres = decoded.libraryGenres
        lastSynced = decoded.fetchedAt
    }

    private func clearCachedData() {
        userDefaults.removeObject(forKey: cachedDataKey)
        userDefaults.removeObject(forKey: lastSyncedKey)
    }
}
