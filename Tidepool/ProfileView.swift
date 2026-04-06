import SwiftUI
import MapKit
import Photos
import Combine
import TidepoolShared

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("photos_opt_in") private var photosOptIn: Bool = false
    @AppStorage("background_enabled") private var backgroundEnabled: Bool = false
    @AppStorage("reduced_accuracy") private var reducedAccuracy: Bool = true

    @StateObject private var location = LocationManager()
    @StateObject private var appleMapsManager = AppleMapsIntegrationManager()
    @StateObject private var photosManager = PhotosIntegrationManager()
    @EnvironmentObject var favoritesManager: InAppFavoritesManager
    @StateObject private var spotifyManager = SpotifyIntegrationManager()
    @StateObject private var appleMusicManager = AppleMusicIntegrationManager()
    @StateObject private var ageRangeManager = AgeRangeManager()

    @State private var vectorManager: InterestVectorManager?
    @State private var showingHomePicker = false
    @State private var photosDeniedAlert = false
    @State private var showingLocationImport = false
    @State private var showingFavorites = false
    @State private var showingPlaceSearch = false
    @State private var showingBirthdayPicker = false
    @State private var tempBirthday: Date = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
    @State private var visitPatterns: [VisitPattern] = []
    @State private var isLoadingVisits = false
    @State private var pendingVisitCount: Int = 0
    @State private var showingPendingVisits = false
    @State private var showingAddHiddenPlace = false
    @AppStorage("home_address") private var homeAddress: String = ""
    @AppStorage("hidden_places_data") private var hiddenPlacesData: Data = Data()

    var body: some View {
        mainForm
            .onReceive(appleMapsManager.$savedLocations) { _ in vectorManager?.computeVector() }
            .onReceive(photosManager.$clusters) { _ in vectorManager?.computeVector() }
            .onReceive(favoritesManager.$favorites) { _ in vectorManager?.computeVector() }
            .onReceive(spotifyManager.$topArtists) { _ in vectorManager?.computeVector() }
            .onReceive(appleMusicManager.$recentlyPlayed) { _ in vectorManager?.computeVector() }
            .onReceive(ageRangeManager.$birthday) { _ in vectorManager?.computeVector() }
    }

    @ViewBuilder
    private var mainForm: some View {
        formContent
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear(perform: handleOnAppear)
            .modifier(ProfileSheetsModifier(
                showingHomePicker: $showingHomePicker,
                showingLocationImport: $showingLocationImport,
                showingFavorites: $showingFavorites,
                showingPlaceSearch: $showingPlaceSearch,
                photosDeniedAlert: $photosDeniedAlert,
                location: location,
                appleMapsManager: appleMapsManager,
                favoritesManager: favoritesManager,
                onHomeSet: { _, address in
                    homeAddress = address
                }
            ))
    }

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                integrationsCard
                visitsCard
                locationCard
                privacyCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color(UIColor.systemGroupedBackground))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(action: {
                HapticFeedbackManager.shared.impact(.light)
                dismiss()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .fontWeight(.semibold)
                    Text("Map")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            Text("Layers")
                .font(.headline)
                .fontWeight(.semibold)
        }
    }

    private func handleOnAppear() {
        location.setBackgroundUpdatesEnabled(backgroundEnabled)
        location.applyReducedAccuracy(reducedAccuracy)

        if vectorManager == nil {
            vectorManager = InterestVectorManager(
                appleMapsManager: appleMapsManager,
                photosManager: photosManager,
                favoritesManager: favoritesManager,
                spotifyManager: spotifyManager,
                appleMusicManager: appleMusicManager,
                ageRangeManager: ageRangeManager
            )
        }

        loadVisitData()
    }

    private func loadVisitData() {
        // Show pending local count
        let pending = UserDefaults.standard.data(forKey: "pending_visits")
            .flatMap { try? JSONDecoder().decode([VisitReport].self, from: $0) }
        pendingVisitCount = pending?.count ?? 0

        // Fetch server patterns
        guard BackendClient.shared.isAuthenticated else { return }
        isLoadingVisits = true
        Task {
            do {
                let response = try await BackendClient.shared.getVisitPatterns()
                visitPatterns = response.patterns
            } catch {
                print("[ProfileView] visit patterns fetch failed: \(error.localizedDescription)")
            }
            isLoadingVisits = false
        }
    }

    // MARK: - Location Section

    @ViewBuilder
    private var locationSection: some View {
        Section(header: Text("Location")) {
            locationPermissionRow
            backgroundToggle
            reducedAccuracyToggle
            homeRow
        }
    }

    @ViewBuilder
    private var locationPermissionRow: some View {
        HStack {
            Label("Location Permission", systemImage: "location")
            Spacer()
            Button("When In Use") { location.requestAuthorization() }
                .buttonStyle(.bordered)
            Button("Always") { location.requestAlwaysAuthorization() }
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var backgroundToggle: some View {
        Toggle(isOn: $backgroundEnabled) {
            Label("Background updates (visits & significant-change)", systemImage: "waveform.path.ecg")
        }
        .onChange(of: backgroundEnabled) { _, enabled in
            location.setBackgroundUpdatesEnabled(enabled)
        }
    }

    @ViewBuilder
    private var reducedAccuracyToggle: some View {
        Toggle(isOn: $reducedAccuracy) {
            Label("Reduced accuracy (battery)", systemImage: "bolt.slash")
        }
        .onChange(of: reducedAccuracy) { _, reduced in
            location.applyReducedAccuracy(reduced)
        }
    }

    @ViewBuilder
    private var homeRow: some View {
        HStack {
            Label("Home", systemImage: "house")
            Spacer()
            if let home = location.homeLocation {
                Text("\(home.latitude, specifier: "%.3f"), \(home.longitude, specifier: "%.3f")")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not set")
                    .foregroundStyle(.secondary)
            }
            Button(location.homeLocation == nil ? "Set" : "Update") { showingHomePicker = true }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Integrations Section

    @ViewBuilder
    private var integrationsSection: some View {
        Section(header: Text("Integrations")) {
            ageRangeRow
            spotifyRow
            appleMusicRow
            photosRow
            photosMetricsRow
        }
    }

    @ViewBuilder
    private var ageRangeRow: some View {
        HStack {
            Label("Birthday", systemImage: "birthday.cake")
            Spacer()

            if ageRangeManager.isAuthorized {
                ageSetMenu
            } else {
                Button("Set") {
                    tempBirthday = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
                    showingBirthdayPicker = true
                }
                .buttonStyle(.bordered)
            }
        }
        .sheet(isPresented: $showingBirthdayPicker) {
            BirthdayPickerSheet(
                birthday: $tempBirthday,
                onSave: { date in
                    ageRangeManager.setBirthday(date)
                    showingBirthdayPicker = false
                },
                onCancel: {
                    showingBirthdayPicker = false
                }
            )
            .presentationDetents([.height(320)])
        }
    }

    @ViewBuilder
    private var ageSetMenu: some View {
        Button {
            tempBirthday = ageRangeManager.birthday ?? Date()
            showingBirthdayPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text(ageRangeManager.displayAge)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private var spotifyRow: some View {
        HStack {
            Label("Spotify", systemImage: "music.note")
            Spacer()

            if spotifyManager.isConnected && spotifyManager.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if spotifyManager.isConnected {
                spotifyConnectedMenu
            } else {
                Button("Connect") {
                    Task {
                        await spotifyManager.authenticate()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var spotifyConnectedMenu: some View {
        Menu {
            Button("Refresh Data") {
                Task {
                    await spotifyManager.refreshData()
                }
            }

            Divider()

            Button("Disconnect", role: .destructive) {
                DispatchQueue.main.async {
                    spotifyManager.disconnect()
                }
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Connected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let summary = spotifyManager.getSummary() {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var appleMusicRow: some View {
        HStack {
            Label("Apple Music", systemImage: "music.note.house")
            Spacer()

            if appleMusicManager.isAuthorized && appleMusicManager.isSyncing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if appleMusicManager.isAuthorized {
                appleMusicConnectedMenu
            } else {
                Button("Connect") {
                    Task {
                        await appleMusicManager.requestAuthorization()
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var appleMusicConnectedMenu: some View {
        Menu {
            Button("Refresh Data") {
                Task {
                    await appleMusicManager.refreshData()
                }
            }

            Divider()

            Button("Disconnect", role: .destructive) {
                appleMusicManager.disconnect()
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Connected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let summary = appleMusicManager.getSummary() {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var photosRow: some View {
        HStack {
            Label("Photos", systemImage: "photo.on.rectangle")
            Spacer()

            if photosManager.isEnabled && photosManager.isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analyzing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if photosManager.isEnabled {
                photosConnectedMenu
            } else {
                Button("Connect") {
                    connectPhotos()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var photosConnectedMenu: some View {
        Menu {
            Button("Refresh Analysis") {
                Task {
                    await photosManager.refreshData()
                }
            }

            Divider()

            Button("Disconnect", role: .destructive) {
                disconnectPhotos()
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Connected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let summary = photosManager.getPlacesSummary() {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var photosMetricsRow: some View {
        if photosManager.isEnabled && !photosManager.isProcessing, let metrics = photosManager.metrics {
            VStack(alignment: .leading, spacing: 4) {
                Text("Discovered \(metrics.clusters.count) frequent places from \(metrics.locationEnabledPhotos) geotagged photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastProcessed = photosManager.lastProcessed {
                    Text("Last updated \(lastProcessed, style: .relative) ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Interest Profile Section

    @ViewBuilder
    private var interestProfileSection: some View {
        Section(header: Text("Interest Profile")) {
            if let vectorManager = vectorManager {
                InterestVectorView(vectorManager: vectorManager)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } else {
                Text("Loading interest profile...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Favorites Section

    @ViewBuilder
    private var favoritesSection: some View {
        Section(header: Text("Favorites")) {
            VStack(alignment: .leading, spacing: 8) {
                favoritesHeader
                favoritesStats
            }
        }
    }

    @ViewBuilder
    private var favoritesHeader: some View {
        HStack {
            Label("My Favorites", systemImage: "heart.fill")
                .foregroundStyle(.red)
            Spacer()
            Button {
                showingPlaceSearch = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            Button("View All") {
                showingFavorites = true
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var favoritesStats: some View {
        let stats = favoritesManager.getStats()
        if stats.totalFavorites > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(stats.totalFavorites) saved places")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if stats.averageRating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                            Text(String(format: "%.1f avg", stats.averageRating))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let topCategory = stats.topCategory {
                    Text("Most loved: \(topCategory.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Start adding places you love to build your personal taste profile")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy Section

    @ViewBuilder
    private var privacySection: some View {
        Section(header: Text("Privacy"), footer: Text("We never show your exact location or identity to others. Presence near Home (within 500 ft) is never shared.")) {
            Label("Anonymous presence only", systemImage: "shield.lefthalf.filled")
            Label("K-anonymity & DP on aggregates", systemImage: "checkerboard.shield")
        }
    }

    // MARK: - Card Components

    private var integrationsCard: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Integrations")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Connect your interests to help Tidepool find your place")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Integration cards with inline insights
            VStack(spacing: 10) {
                // Birthday
                Button {
                    tempBirthday = ageRangeManager.birthday ?? Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date()
                    showingBirthdayPicker = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "birthday.cake.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.pink.gradient)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .shadow(color: .pink.opacity(0.3), radius: 4, y: 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Birthday")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                            if ageRangeManager.isAuthorized {
                                Text(ageRangeManager.displayAge)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        Image(systemName: ageRangeManager.isAuthorized ? "pencil" : "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .clipShape(Circle())
                            .shadow(color: .blue.opacity(0.3), radius: 4, y: 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                // Favorites — special: plus button + tapping opens favorites list
                favoritesIntegrationCard()

                // Spotify
                tappableIntegrationCard(
                    icon: "waveform", title: "Spotify", tint: .green,
                    isConnected: spotifyManager.isConnected,
                    isSyncing: spotifyManager.isConnected && spotifyManager.isSyncing,
                    summary: spotifyManager.getSummary(),
                    tags: vectorManager?.getSourceInsights().first(where: { $0.name == "Spotify" })?.topTags ?? [],
                    onConnect: { Task { await spotifyManager.authenticate() } },
                    onRefresh: { Task { await spotifyManager.refreshData() } },
                    onDisconnect: { spotifyManager.disconnect() }
                )

                // Apple Music
                tappableIntegrationCard(
                    icon: "music.note", title: "Apple Music", tint: .red,
                    isConnected: appleMusicManager.isAuthorized,
                    isSyncing: appleMusicManager.isAuthorized && appleMusicManager.isSyncing,
                    summary: appleMusicManager.getSummary(),
                    tags: vectorManager?.getSourceInsights().first(where: { $0.name == "Apple Music" })?.topTags ?? [],
                    onConnect: { Task { await appleMusicManager.requestAuthorization() } },
                    onRefresh: { Task { await appleMusicManager.refreshData() } },
                    onDisconnect: { appleMusicManager.disconnect() }
                )

                // Photos
                tappableIntegrationCard(
                    icon: "photo.fill", title: "Photos", tint: .orange,
                    isConnected: photosManager.isEnabled,
                    isSyncing: photosManager.isEnabled && photosManager.isProcessing,
                    summary: photosManager.getPlacesSummary(),
                    tags: vectorManager?.getSourceInsights().first(where: { $0.name == "Photos" })?.topTags ?? [],
                    onConnect: { connectPhotos() },
                    onRefresh: { Task { await photosManager.refreshData() } },
                    onDisconnect: { disconnectPhotos() }
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .blue.opacity(0.08), radius: 12, y: 4)
    }

    private func integrationPill<T: View>(icon: String, title: String, tint: Color, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: tint.opacity(0.3), radius: 4, y: 2)

            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Integration card where tapping the header triggers connect or shows a menu.
    private func tappableIntegrationCard(
        icon: String, title: String, tint: Color,
        isConnected: Bool, isSyncing: Bool = false,
        summary: String?, tags: [InterestVectorManager.TagWeight],
        onConnect: @escaping () -> Void,
        onRefresh: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 0) {
            // Header row — always visible, never replaced by Menu label
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(tint.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: tint.opacity(0.3), radius: 4, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    if let summary, isConnected {
                        Text(summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else if isConnected {
                    // Checkmark with invisible Menu overlay so it never disappears
                    ZStack {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .clipShape(Circle())
                            .shadow(color: .green.opacity(0.3), radius: 4, y: 2)

                        Menu {
                            Button { onRefresh() } label: {
                                Label("Refresh Data", systemImage: "arrow.clockwise")
                            }
                            Divider()
                            Button(role: .destructive) { onDisconnect() } label: {
                                Label("Disconnect", systemImage: "xmark.circle")
                            }
                        } label: {
                            Color.clear.frame(width: 28, height: 28)
                        }
                    }
                } else {
                    Button { onConnect() } label: {
                        Text("Connect")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                            )
                            .clipShape(Capsule())
                            .shadow(color: .blue.opacity(0.25), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Inline donut chart or skeleton
            if isConnected && !tags.isEmpty && !isSyncing {
                Divider()
                    .padding(.horizontal, 16)
                DonutChartView(tags: tags, size: 64, lineWidth: 14)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            } else if isConnected && isSyncing {
                Divider()
                    .padding(.horizontal, 16)
                DonutSkeletonView()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// Favorites card — plus button to add, tapping header opens favorites list
    private func favoritesIntegrationCard() -> some View {
        let tags = vectorManager?.getSourceInsights().first(where: { $0.name == "Favorites" })?.topTags ?? []

        return VStack(spacing: 0) {
            Button { showingFavorites = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.yellow.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: .yellow.opacity(0.3), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Favorites")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        if !favoritesManager.favorites.isEmpty {
                            Text("\(favoritesManager.favorites.count) places")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    Button { showingPlaceSearch = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(
                                LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .clipShape(Circle())
                            .shadow(color: .blue.opacity(0.3), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if !tags.isEmpty {
                Divider()
                    .padding(.horizontal, 16)
                DonutChartView(tags: tags, size: 64, lineWidth: 14)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var syncingBadge: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Syncing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var interestProfileCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Taste")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("What makes you, you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if let vectorManager = vectorManager {
                InterestVectorView(vectorManager: vectorManager)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building your taste profile...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .purple.opacity(0.08), radius: 12, y: 4)
    }

    private var visitsCard: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check-ins")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Places you've visited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if isLoadingVisits {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading visits...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
            } else if visitPatterns.isEmpty && pendingVisitCount == 0 {
                VStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No visits detected yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tidepool detects visits when you stay at a place for 5+ minutes")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            } else {
                VStack(spacing: 8) {
                    // Pending local visits badge — tappable for details
                    if pendingVisitCount > 0 {
                        Button { showingPendingVisits = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.subheadline)
                                Text("\(pendingVisitCount) pending upload")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                    }

                    // Server-synced visit patterns
                    ForEach(Array(visitPatterns.prefix(8).enumerated()), id: \.offset) { i, pattern in
                        visitPatternRow(pattern, index: i)
                    }

                    if visitPatterns.count > 8 {
                        Text("+ \(visitPatterns.count - 8) more places")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .cyan.opacity(0.08), radius: 12, y: 4)
        .sheet(isPresented: $showingPendingVisits) {
            PendingVisitsSheet(onDismiss: {
                showingPendingVisits = false
                loadVisitData() // refresh counts
            })
        }
    }

    private let visitColors: [Color] = [.cyan, .blue, .teal, .indigo, .purple, .green, .orange, .mint]

    private func visitPatternRow(_ pattern: VisitPattern, index: Int) -> some View {
        let color = visitColors[index % visitColors.count]
        let categoryIcon = (PlaceCategory(rawValue: pattern.category.rawValue) ?? .other).iconName

        return HStack(spacing: 12) {
            Image(systemName: categoryIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(pattern.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(pattern.visitCount) visit\(pattern.visitCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !pattern.typicalHours.isEmpty {
                        let hourStr = pattern.typicalHours.prefix(2)
                            .map { formatHour($0) }
                            .joined(separator: ", ")
                        Text("around \(hourStr)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Text("\(pattern.avgDurationMinutes)m")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let ampm = hour < 12 ? "am" : "pm"
        return "\(h)\(ampm)"
    }

    private var favoritesCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favorites")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("Places you love")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button { showingPlaceSearch = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(Circle())
                        .shadow(color: .pink.opacity(0.3), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            let stats = favoritesManager.getStats()
            if stats.totalFavorites > 0 {
                Button { showingFavorites = true } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(stats.totalFavorites) saved places")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)

                            if let top = stats.topCategory {
                                Text("Most loved: \(top.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if stats.averageRating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", stats.averageRating))
                                    .fontWeight(.semibold)
                            }
                            .font(.subheadline)
                        }

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            } else {
                Text("Add places you love to build your taste profile")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }

            Spacer().frame(height: 8)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .orange.opacity(0.08), radius: 12, y: 4)
    }

    private var locationCard: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Location")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("How Tidepool sees the world around you")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            VStack(spacing: 8) {
                locationSettingRow(icon: "location.fill", title: "Permission", tint: .blue) {
                    HStack(spacing: 6) {
                        Button("When In Use") { location.requestAuthorization() }
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                        Button("Always") { location.requestAlwaysAuthorization() }
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                locationToggleRow(icon: "waveform.path.ecg", title: "Background updates", tint: .purple, isOn: $backgroundEnabled)

                locationToggleRow(icon: "bolt.slash.fill", title: "Reduced accuracy", tint: .yellow, isOn: $reducedAccuracy)

                Button { showingHomePicker = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.orange.gradient)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Home")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if !homeAddress.isEmpty {
                                Text(homeAddress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: location.homeLocation == nil ? "plus" : "pencil")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .clipShape(Circle())
                            .shadow(color: .blue.opacity(0.3), radius: 4, y: 2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                // Hidden places
                hiddenPlacesSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .indigo.opacity(0.06), radius: 12, y: 4)
    }

    // MARK: - Hidden Places

    private var hiddenPlaces: [HiddenPlace] {
        (try? JSONDecoder().decode([HiddenPlace].self, from: hiddenPlacesData)) ?? []
    }

    private func saveHiddenPlaces(_ places: [HiddenPlace]) {
        hiddenPlacesData = (try? JSONEncoder().encode(places)) ?? Data()
    }

    private var hiddenPlacesSection: some View {
        VStack(spacing: 8) {
            ForEach(hiddenPlaces) { place in
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.purple.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(place.address)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        var places = hiddenPlaces
                        places.removeAll { $0.id == place.id }
                        saveHiddenPlaces(places)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            Button { showingAddHiddenPlace = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.purple)
                    Text("Add hidden place")
                        .font(.subheadline)
                        .foregroundStyle(.purple)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.purple.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingAddHiddenPlace) {
            HiddenPlacePicker { place in
                var places = hiddenPlaces
                places.append(place)
                saveHiddenPlaces(places)
                showingAddHiddenPlace = false
            }
            .presentationDetents([.large])
        }
    }

    private func locationSettingRow<T: View>(icon: String, title: String, tint: Color, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.subheadline)

            Spacer()

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func locationToggleRow(icon: String, title: String, tint: Color, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(title)
                .font(.subheadline)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var privacyCard: some View {
        VStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Privacy")
                    .font(.title3)
                    .fontWeight(.bold)
                Text("Your data stays yours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)

            VStack(spacing: 8) {
                privacyBadge(
                    icon: "shield.lefthalf.filled",
                    tint: .green,
                    title: "Fully anonymous",
                    subtitle: "No accounts, no identity, no tracking"
                )
                privacyBadge(
                    icon: "eye.slash.fill",
                    tint: .blue,
                    title: "Home protected",
                    subtitle: "Presence hidden within 500 ft of home"
                )
                privacyBadge(
                    icon: "lock.fill",
                    tint: .purple,
                    title: "Encrypted in transit",
                    subtitle: "All data encrypted between device and server"
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .green.opacity(0.06), radius: 12, y: 4)
    }

    private func privacyBadge(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(tint.gradient)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Actions

    private func connectPhotos() {
        Task {
            // Request permission and automatically start analysis
            await photosManager.requestPermission()

            // Update UI based on authorization status
            if photosManager.authorizationStatus == .denied || photosManager.authorizationStatus == .restricted {
                photosDeniedAlert = true
            } else if photosManager.authorizationStatus == .authorized || photosManager.authorizationStatus == .limited {
                // Permission granted - start automatic analysis
                photosOptIn = true
                await photosManager.refreshData()
            }
        }
    }

    private func disconnectPhotos() {
        photosManager.setEnabled(false)
        photosOptIn = false

        // Add haptic feedback
        HapticFeedbackManager.shared.impact(.light)
    }
}

struct SimpleHomePicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchCompleter = PlaceSearchCompleter()
    @State private var searchText = ""
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedAddress: String?
    @State private var suppressNextChange = false
    @FocusState private var isFieldFocused: Bool
    let current: CLLocationCoordinate2D?
    let onSelect: (CLLocationCoordinate2D, String) -> Void

    init(current: CLLocationCoordinate2D?, onSelect: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.current = current
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Set Home")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    if let coord = selectedCoordinate, let addr = selectedAddress {
                        onSelect(coord, addr)
                        dismiss()
                    }
                }
                .fontWeight(.semibold)
                .disabled(selectedCoordinate == nil)
            }
            .padding()

            Divider()

            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Enter your home address...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .medium))
                    .focused($isFieldFocused)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        selectedCoordinate = nil
                        selectedAddress = nil
                        searchCompleter.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(Capsule())
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Selected address confirmation
            if let address = selectedAddress {
                HStack(spacing: 12) {
                    Image(systemName: "house.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(address)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Your presence will be hidden within 500 ft of this location")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Suggestions
            if !searchCompleter.suggestions.isEmpty && selectedAddress == nil {
                List {
                    ForEach(searchCompleter.suggestions, id: \.self) { suggestion in
                        Button {
                            resolveAndSelect(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            } else if selectedAddress == nil {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "house")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    if let current {
                        Text("Home is currently set")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.4f, %.4f", current.latitude, current.longitude))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("Search for your home address")
                            .font(.subheadline)
                            .foregroundStyle(.quaternary)
                    }
                }
                Spacer()
            } else {
                Spacer()
            }
        }
        .fontDesign(.rounded)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFieldFocused = true
            }
        }
        .onChange(of: searchText) { _, newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            selectedCoordinate = nil
            selectedAddress = nil
            searchCompleter.search(newValue)
        }
    }

    private func resolveAndSelect(_ suggestion: MKLocalSearchCompletion) {
        isFieldFocused = false
        searchCompleter.clear()
        let request = MKLocalSearch.Request(completion: suggestion)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first,
               let location = item.placemark.location {
                selectedCoordinate = location.coordinate
                // Short address: just the street portion
                let shortAddress = suggestion.title
                selectedAddress = shortAddress
                suppressNextChange = true
                searchText = shortAddress
            }
        }
    }
}

// MARK: - Profile Sheets Modifier

struct ProfileSheetsModifier: ViewModifier {
    @Binding var showingHomePicker: Bool
    @Binding var showingLocationImport: Bool
    @Binding var showingFavorites: Bool
    @Binding var showingPlaceSearch: Bool
    @Binding var photosDeniedAlert: Bool
    let location: LocationManager
    let appleMapsManager: AppleMapsIntegrationManager
    let favoritesManager: InAppFavoritesManager
    var onHomeSet: ((CLLocationCoordinate2D, String) -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingHomePicker) {
                SimpleHomePicker(current: location.homeLocation) { coord, address in
                    location.setHome(to: coord)
                    onHomeSet?(coord, address)
                }
            }
            .sheet(isPresented: $showingLocationImport) {
                ManualLocationImportView(appleMapsManager: appleMapsManager)
            }
            .sheet(isPresented: $showingFavorites) {
                FavoritesListView(favoritesManager: favoritesManager)
            }
            .sheet(isPresented: $showingPlaceSearch) {
                PlaceSearchView()
                    .environmentObject(favoritesManager)
            }
            .alert("Photos Access Required", isPresented: $photosDeniedAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Open Settings") {
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
            } message: {
                Text("Tidepool needs access to your Photos to discover your favorite places from photo locations. Enable Photos access in Settings to connect.")
            }
    }
}

// MARK: - Birthday Picker Sheet

struct BirthdayPickerSheet: View {
    @Binding var birthday: Date
    let onSave: (Date) -> Void
    let onCancel: () -> Void

    private var calculatedAge: Int {
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthday, to: Date())
        return ageComponents.year ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .foregroundStyle(.secondary)

                Spacer()

                Text("Birthday")
                    .font(.headline)

                Spacer()

                Button("Save") {
                    onSave(birthday)
                }
                .fontWeight(.semibold)
            }
            .padding()

            Divider()

            // Date picker wheel
            DatePicker(
                "",
                selection: $birthday,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()

            // Age preview
            Text("\(calculatedAge) years old")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom)
        }
    }
}

// MARK: - Pending Visits Debug Sheet

struct PendingVisitsSheet: View {
    let onDismiss: () -> Void
    private let detector = VisitDetector.shared
    private let iso = ISO8601DateFormatter()

    var body: some View {
        NavigationView {
            List {
                // Status section
                Section("Upload Status") {
                    if let lastDate = detector.lastUploadDate {
                        HStack {
                            Label("Last upload", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Text(lastDate, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let error = detector.lastUploadError {
                        HStack {
                            Label("Last error", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }

                    Button {
                        detector.retryUpload()
                    } label: {
                        Label("Retry Upload Now", systemImage: "arrow.clockwise")
                    }

                    Button(role: .destructive) {
                        detector.clearPending()
                        onDismiss()
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }

                // Pending visits
                Section("Pending Visits (\(detector.pendingVisits.count))") {
                    if detector.pendingVisits.isEmpty {
                        Text("Queue is empty")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(detector.pendingVisits.enumerated()), id: \.offset) { _, visit in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(visit.name)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(visit.source)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(visit.source == "visit" ? Color.blue : (visit.source == "photo" ? Color.orange : Color.yellow))
                                        .clipShape(Capsule())
                                }

                                HStack(spacing: 12) {
                                    Label(visit.category.rawValue, systemImage: "tag")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Label(String(format: "%.4f, %.4f", visit.latitude, visit.longitude), systemImage: "location")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 12) {
                                    Label("\(visit.durationMinutes)m", systemImage: "clock")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Label("confidence: \(String(format: "%.0f%%", visit.confidence * 100))", systemImage: "gauge.medium")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if let poiId = visit.poiId {
                                    Text("POI: \(poiId)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                if let yelpId = visit.yelpId {
                                    Text("Yelp: \(yelpId)")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Text(visit.arrivedAt)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Upload Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { onDismiss() }
                }
            }
        }
    }
}

// MARK: - Hidden Place Model

struct HiddenPlace: Identifiable, Codable {
    let id: UUID
    let name: String
    let address: String
    let latitude: Double
    let longitude: Double

    init(name: String, address: String, latitude: Double, longitude: Double) {
        self.id = UUID()
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Hidden Place Picker

struct HiddenPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var searchCompleter = PlaceSearchCompleter()
    @State private var searchText = ""
    @State private var placeName = ""
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var selectedAddress: String?
    @State private var suppressNextChange = false
    @FocusState private var isNameFocused: Bool
    @FocusState private var isAddressFocused: Bool
    let onSave: (HiddenPlace) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Add Hidden Place")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    if let coord = selectedCoordinate, let addr = selectedAddress, !placeName.isEmpty {
                        onSave(HiddenPlace(name: placeName, address: addr, latitude: coord.latitude, longitude: coord.longitude))
                    }
                }
                .fontWeight(.semibold)
                .disabled(selectedCoordinate == nil || placeName.isEmpty)
            }
            .padding()

            Divider()

            VStack(spacing: 12) {
                // Name field
                HStack(spacing: 10) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    TextField("Name (e.g. Work, Gym)", text: $placeName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($isNameFocused)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(UIColor.tertiarySystemFill))
                .clipShape(Capsule())

                // Address search
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    TextField("Search address...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($isAddressFocused)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            selectedCoordinate = nil
                            selectedAddress = nil
                            searchCompleter.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(UIColor.tertiarySystemFill))
                .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Selected confirmation
            if let address = selectedAddress {
                HStack(spacing: 12) {
                    Image(systemName: "eye.slash.fill")
                        .font(.title2)
                        .foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("Your presence will be hidden within 500 ft")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.purple.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }

            // Suggestions
            if !searchCompleter.suggestions.isEmpty && selectedAddress == nil {
                List {
                    ForEach(searchCompleter.suggestions, id: \.self) { suggestion in
                        Button {
                            resolveAddress(suggestion)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            } else {
                Spacer()
            }
        }
        .fontDesign(.rounded)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { isNameFocused = true }
        }
        .onChange(of: searchText) { _, newValue in
            if suppressNextChange {
                suppressNextChange = false
                return
            }
            selectedCoordinate = nil
            selectedAddress = nil
            searchCompleter.search(newValue)
        }
    }

    private func resolveAddress(_ suggestion: MKLocalSearchCompletion) {
        isAddressFocused = false
        searchCompleter.clear()
        let request = MKLocalSearch.Request(completion: suggestion)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first, let loc = item.placemark.location {
                selectedCoordinate = loc.coordinate
                selectedAddress = suggestion.title
                suppressNextChange = true
                searchText = suggestion.title
            }
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(InAppFavoritesManager())
}
