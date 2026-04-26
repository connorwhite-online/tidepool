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
    @State private var recentVisits: [VisitReport] = []
    @State private var isLoadingVisits = false
    @State private var pendingVersion: Int = 0
    @State private var showingAddHiddenPlace = false
    @State private var showingInsights = false
    @State private var showingCheckInsList = false
    @State private var initialCheckInDetail: CheckInItem? = nil
    @State private var activeIntegrationMenu: ActiveIntegrationMenu? = nil
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
            .padding(.bottom, 4)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .overlayPreferenceValue(IntegrationCardBoundsKey.self) { anchors in
            GeometryReader { geom in
                if let menu = activeIntegrationMenu, let anchor = anchors[menu.id] {
                    let rect = geom[anchor]
                    let spacing: CGFloat = 8
                    let popupHeight: CGFloat = 92
                    let placeBelow = rect.maxY + spacing + popupHeight < geom.size.height
                    let popupY = placeBelow ? rect.maxY + spacing : rect.minY - spacing - popupHeight

                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.0001)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.bouncy(duration: 0.28, extraBounce: 0.35)) {
                                    activeIntegrationMenu = nil
                                }
                            }
                            .transition(.opacity)

                        IntegrationActionsPopup(menu: menu) {
                            withAnimation(.bouncy(duration: 0.28, extraBounce: 0.35)) {
                                activeIntegrationMenu = nil
                            }
                        }
                        .frame(width: rect.width, height: popupHeight)
                        .offset(x: rect.minX, y: popupY)
                        .transition(
                            .scale(scale: 0.6, anchor: placeBelow ? .top : .bottom)
                                .combined(with: .opacity)
                        )
                    }
                }
            }
        }
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
        pendingVersion &+= 1

        guard BackendClient.shared.isAuthenticated else { return }
        isLoadingVisits = true
        Task {
            do {
                recentVisits = try await BackendClient.shared.getRecentVisits(limit: 50)
            } catch {
                print("[ProfileView] visit data fetch failed: \(error.localizedDescription)")
            }
            isLoadingVisits = false
        }
    }

    private var allCheckIns: [CheckInItem] {
        _ = pendingVersion // re-evaluate when pending changes
        let iso = ISO8601DateFormatter()
        var items: [CheckInItem] = []

        for (i, v) in VisitDetector.shared.pendingVisits.enumerated() {
            let d = iso.date(from: v.arrivedAt) ?? Date.distantPast
            items.append(CheckInItem(
                id: "p_\(v.arrivedAt)_\(v.name)",
                visit: v,
                isPending: true,
                date: d,
                pendingIndex: i
            ))
        }
        for v in recentVisits {
            let d = iso.date(from: v.arrivedAt) ?? Date.distantPast
            items.append(CheckInItem(
                id: "s_\(v.arrivedAt)_\(v.name)",
                visit: v,
                isPending: false,
                date: d,
                pendingIndex: nil
            ))
        }
        return items.sorted { $0.date > $1.date }
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
                        Image("birthday")
                            .scaleEffect(2.0)
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
                IntegrationCardView(
                    id: "spotify",
                    icon: "spotify", title: "Spotify", tint: .green,
                    isConnected: spotifyManager.isConnected,
                    isSyncing: spotifyManager.isConnected && spotifyManager.isSyncing,
                    summary: spotifyManager.getSummary(),
                    onConnect: { Task { await spotifyManager.authenticate() } },
                    onRefresh: { Task { await spotifyManager.refreshData() } },
                    onDisconnect: { spotifyManager.disconnect() },
                    activeMenu: $activeIntegrationMenu
                )

                // Apple Music
                IntegrationCardView(
                    id: "appleMusic",
                    icon: "apple-music", title: "Apple Music", tint: .red,
                    isConnected: appleMusicManager.isAuthorized,
                    isSyncing: appleMusicManager.isAuthorized && appleMusicManager.isSyncing,
                    summary: appleMusicManager.getSummary(),
                    onConnect: { Task { await appleMusicManager.requestAuthorization() } },
                    onRefresh: { Task { await appleMusicManager.refreshData() } },
                    onDisconnect: { appleMusicManager.disconnect() },
                    activeMenu: $activeIntegrationMenu
                )

                // Photos
                IntegrationCardView(
                    id: "photos",
                    icon: "image", title: "Photos", tint: .orange,
                    isConnected: photosManager.isEnabled,
                    isSyncing: photosManager.isEnabled && photosManager.isProcessing,
                    summary: photosManager.getPlacesSummary(),
                    onConnect: { connectPhotos() },
                    onRefresh: { Task { await photosManager.refreshData() } },
                    onDisconnect: { disconnectPhotos() },
                    activeMenu: $activeIntegrationMenu
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            // View Insights link
            if let vectorManager {
                Button { showingInsights = true } label: {
                    HStack(spacing: 6) {
                        Text("View Insights")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .fontWeight(.bold)
                    }
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .sheet(isPresented: $showingInsights) {
                    InterestInsightsDetailView(vectorManager: vectorManager, photosManager: photosManager)
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .blue.opacity(0.08), radius: 12, y: 4)
    }

    private func integrationPill<T: View>(icon: String, title: String, tint: Color, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 12) {
            AdaptiveSymbol(name: icon)
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


    /// Favorites card — plus button to add, tapping header opens favorites list
    private func favoritesIntegrationCard() -> some View {
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
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let items = allCheckIns
        let inlineCount = 3

        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check-ins")
                        .font(.title3)
                        .fontWeight(.bold)
                    Text(items.isEmpty ? "Places you've visited" : "\(items.count) place\(items.count == 1 ? "" : "s") visited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if items.count > inlineCount {
                    Button {
                        initialCheckInDetail = nil
                        showingCheckInsList = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("View All")
                                .font(.caption)
                                .fontWeight(.semibold)
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if isLoadingVisits && items.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading visits...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 20)
            } else if items.isEmpty {
                VStack(spacing: 6) {
                    Image("map-pin")
                        .scaleEffect(2.0)
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
                VStack(spacing: 6) {
                    ForEach(items.prefix(inlineCount)) { item in
                        Button {
                            initialCheckInDetail = item
                            showingCheckInsList = true
                        } label: {
                            CheckInRowView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .cyan.opacity(0.08), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !allCheckIns.isEmpty else { return }
            initialCheckInDetail = nil
            showingCheckInsList = true
        }
        .sheet(isPresented: $showingCheckInsList, onDismiss: { loadVisitData() }) {
            CheckInsListSheet(items: allCheckIns, initialDetail: initialCheckInDetail) {
                loadVisitData()
            }
        }
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
                locationSettingRow(icon: "location", title: "Permission", tint: .blue) {
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
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.purple.gradient)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text("Add hidden place")
                        .font(.subheadline)

                    Spacer()

                    Image(systemName: "plus")
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
            AdaptiveSymbol(name: icon)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Tidepool is fully anonymous — no accounts, identity, or tracking.")
                Text("Your home location stays hidden within 500 feet, and everything is encrypted in transit.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
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

/// Bounds of each integration card (in a coordinate space named "integrationsArea"),
/// used to anchor the active popup at the parent level so a screen-wide scrim can dismiss it.
struct IntegrationCardBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ActiveIntegrationMenu: Equatable {
    let id: String
    let title: String
    let onRefresh: () -> Void
    let onDisconnect: () -> Void

    static func == (lhs: ActiveIntegrationMenu, rhs: ActiveIntegrationMenu) -> Bool {
        lhs.id == rhs.id
    }
}

/// Integration card: tap anywhere → connect (when disconnected) or set parent's active menu (when connected).
/// The popup itself is rendered by the parent so a screen-wide scrim can intercept outside taps.
struct IntegrationCardView: View {
    let id: String
    let icon: String
    let title: String
    let tint: Color
    let isConnected: Bool
    let isSyncing: Bool
    let summary: String?
    let onConnect: () -> Void
    let onRefresh: () -> Void
    let onDisconnect: () -> Void
    @Binding var activeMenu: ActiveIntegrationMenu?

    var body: some View {
        Button {
            if isConnected {
                let menu = ActiveIntegrationMenu(
                    id: id, title: title,
                    onRefresh: onRefresh, onDisconnect: onDisconnect
                )
                withAnimation(.bouncy(duration: 0.28, extraBounce: 0.35)) {
                    activeMenu = (activeMenu?.id == id) ? nil : menu
                }
            } else {
                onConnect()
            }
        } label: {
            cardRow
        }
        .buttonStyle(.plain)
        .anchorPreference(key: IntegrationCardBoundsKey.self, value: .bounds) { [id: $0] }
    }

    private var cardRow: some View {
        HStack(spacing: 12) {
            AdaptiveSymbol(name: icon)
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
                    .foregroundStyle(.primary)
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
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .clipShape(Circle())
                    .shadow(color: .green.opacity(0.3), radius: 4, y: 2)
            } else {
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }

}

/// Popup rendered by the parent over the active integration card.
/// Owns its own dismiss-on-action behavior so the parent only needs to pass the data.
struct IntegrationActionsPopup: View {
    let menu: ActiveIntegrationMenu
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            popupItem(label: "Refresh Data", icon: "arrow.clockwise") {
                menu.onRefresh()
            }
            Divider()
            popupItem(label: "Disconnect", icon: "xmark.circle", isDestructive: true) {
                menu.onDisconnect()
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private func popupItem(label: String, icon: String, isDestructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            onDismiss()
            action()
        } label: {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Image(systemName: icon)
                    .font(.subheadline)
            }
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    let currentAddress: String?
    let onSelect: (CLLocationCoordinate2D, String) -> Void

    init(current: CLLocationCoordinate2D?, currentAddress: String? = nil, onSelect: @escaping (CLLocationCoordinate2D, String) -> Void) {
        self.current = current
        self.currentAddress = currentAddress
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
                        if let addr = currentAddress, !addr.isEmpty {
                            Text(addr)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
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
                SimpleHomePicker(current: location.homeLocation, currentAddress: UserDefaults.standard.string(forKey: "home_address")) { coord, address in
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

// MARK: - Check-in unified list

struct CheckInItem: Identifiable, Hashable {
    let id: String
    let visit: VisitReport
    let isPending: Bool
    let date: Date
    let pendingIndex: Int?

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (a: CheckInItem, b: CheckInItem) -> Bool { a.id == b.id }
}

struct CheckInRowView: View {
    let item: CheckInItem

    private var timeStr: String {
        let iso = ISO8601DateFormatter()
        guard let date = iso.date(from: item.visit.arrivedAt) else { return item.visit.arrivedAt }
        if item.isPending {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image("map-pin")
                .scaleEffect(2.0)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background((item.isPending ? Color.orange : Color.cyan).gradient)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.visit.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(item.visit.durationMinutes)m")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(timeStr)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if item.isPending {
                Text("Pending")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.orange.opacity(0.15))
                    .clipShape(Capsule())
            }

            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

enum CheckInRoute: Hashable {
    case detail(String)
    case debug
}

struct CheckInsListSheet: View {
    let items: [CheckInItem]
    let initialDetail: CheckInItem?
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: [CheckInRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        Button {
                            path.append(.detail(item.id))
                        } label: {
                            CheckInRowView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Check-ins")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: CheckInRoute.self) { route in
                switch route {
                case .detail(let id):
                    if let item = items.first(where: { $0.id == id }) {
                        CheckInDetailView(
                            item: item,
                            onChange: onChange,
                            onDelete: { onChange(); path.removeLast() }
                        )
                    }
                case .debug:
                    PendingQueueDebugView(onChange: onChange)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if items.contains(where: { $0.isPending }) {
                        Button { path.append(.debug) } label: {
                            Text("Debug")
                                .font(.subheadline)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if let initial = initialDetail {
                path = [.detail(initial.id)]
            }
        }
    }
}

struct CheckInDetailView: View {
    let item: CheckInItem
    let onChange: () -> Void
    let onDelete: () -> Void

    @State private var showingRelink = false
    @StateObject private var searchCompleter = PlaceSearchCompleter()
    @State private var searchText = ""
    @State private var suppressNextChange = false

    private var visit: VisitReport { item.visit }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.003, longitudeDelta: 0.003)
                ))) {
                    Marker(visit.name, coordinate: CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude))
                        .tint(item.isPending ? .orange : .green)
                }
                .frame(height: 200)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(visit.name)
                            .font(.title3)
                            .fontWeight(.bold)
                        Spacer()
                        Text(item.isPending ? "Pending" : "Synced")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(item.isPending ? Color.orange : Color.green)
                            .clipShape(Capsule())
                    }

                    HStack(spacing: 16) {
                        Label(visit.category.rawValue, systemImage: "tag")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label("\(visit.durationMinutes) min", systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    let iso = ISO8601DateFormatter()
                    if let date = iso.date(from: visit.arrivedAt) {
                        Label(date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Label(String(format: "%.5f, %.5f", visit.latitude, visit.longitude), systemImage: "location")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if item.isPending {
                        Label("Confidence: \(Int(visit.confidence * 100))%", systemImage: "gauge.medium")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(16)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if item.isPending, item.pendingIndex != nil {
                    Button { showingRelink = true } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.subheadline)
                            Text("Link to different place")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let idx = item.pendingIndex {
                            VisitDetector.shared.removeVisit(at: idx)
                        }
                        onDelete()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .font(.subheadline)
                            Text("Delete check-in")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.red.opacity(0.1))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("Check-in Detail")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingRelink) {
            relinkSheet
        }
    }

    private var relinkSheet: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("Search for the correct place...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color(UIColor.tertiarySystemFill))
                .clipShape(Capsule())
                .padding(.horizontal, 16)
                .padding(.top, 16)

                if !searchCompleter.suggestions.isEmpty {
                    List {
                        ForEach(searchCompleter.suggestions, id: \.self) { suggestion in
                            Button {
                                relinkToSuggestion(suggestion)
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
                    Text("Search for the place you actually visited")
                        .font(.subheadline)
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
            }
            .fontDesign(.rounded)
            .navigationTitle("Re-link Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showingRelink = false }
                }
            }
            .onChange(of: searchText) { _, newValue in
                if suppressNextChange { suppressNextChange = false; return }
                searchCompleter.search(newValue)
            }
            .onAppear {
                searchCompleter.updateRegion(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude),
                    latitudinalMeters: 2000, longitudinalMeters: 2000
                ))
            }
        }
    }

    private func relinkToSuggestion(_ suggestion: MKLocalSearchCompletion) {
        guard let idx = item.pendingIndex else { return }

        let request = MKLocalSearch.Request(completion: suggestion)
        MKLocalSearch(request: request).start { response, _ in
            guard let mapItem = response?.mapItems.first else { return }

            let newName = mapItem.name ?? suggestion.title
            let newCoord = mapItem.placemark.location?.coordinate ?? CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
            let newCategory = PlaceCategory.from(mapItem: mapItem)

            let updated = VisitReport(
                poiId: FavoriteLocation.stablePlaceId(name: newName, coordinate: newCoord),
                yelpId: visit.yelpId,
                name: newName,
                category: TidepoolShared.PlaceCategory(rawValue: newCategory.rawValue) ?? .other,
                latitude: newCoord.latitude,
                longitude: newCoord.longitude,
                arrivedAt: visit.arrivedAt,
                departedAt: visit.departedAt,
                dayOfWeek: visit.dayOfWeek,
                hourOfDay: visit.hourOfDay,
                durationMinutes: visit.durationMinutes,
                confidence: 1.0,
                source: visit.source
            )

            VisitDetector.shared.updateVisit(at: idx, with: updated)
            onChange()
            showingRelink = false
        }
    }
}

struct PendingQueueDebugView: View {
    let onChange: () -> Void
    private let detector = VisitDetector.shared

    var body: some View {
        List {
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
                    onChange()
                } label: {
                    Label("Clear Queue", systemImage: "trash")
                }
            }

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
    }
}

// MARK: - Photo Places Sheet

struct MergedPhotoPlace: Identifiable {
    let id = UUID()
    let name: String
    let category: PlaceCategory
    var photoCount: Int
    var firstVisit: Date
    var lastVisit: Date
    var clusterCount: Int
}

struct PhotoPlacesSheet: View {
    @ObservedObject var photosManager: PhotosIntegrationManager
    @Environment(\.dismiss) private var dismiss

    private var nonHome: [PhotoLocationCluster] {
        let filtered = photosManager.clusters.filter { $0.category != .home }
        let exclusionRadius: Double = 152.4
        var exclusionPoints: [CLLocation] = []

        if let data = UserDefaults.standard.data(forKey: "home_location"),
           let coords = try? JSONDecoder().decode([Double].self, from: data), coords.count == 2 {
            exclusionPoints.append(CLLocation(latitude: coords[0], longitude: coords[1]))
        }
        if let data = UserDefaults.standard.data(forKey: "hidden_places_data"),
           let places = try? JSONDecoder().decode([HiddenPlace].self, from: data) {
            for place in places {
                exclusionPoints.append(CLLocation(latitude: place.latitude, longitude: place.longitude))
            }
        }

        guard !exclusionPoints.isEmpty else { return filtered }
        return filtered.filter { cluster in
            let loc = CLLocation(latitude: cluster.centerCoordinate.latitude, longitude: cluster.centerCoordinate.longitude)
            return !exclusionPoints.contains { $0.distance(from: loc) < exclusionRadius }
        }
    }

    private var matchedRaw: [PhotoLocationCluster] {
        nonHome.filter { InterestVectorManager.isLegitPlaceName($0) }
    }

    /// Merged matched places — deduped by name, summing photo counts and widening date ranges
    private var matched: [MergedPhotoPlace] {
        var byName: [String: MergedPhotoPlace] = [:]
        for cluster in matchedRaw {
            let name = cluster.inferredName ?? ""
            if var existing = byName[name] {
                existing.photoCount += cluster.photoCount
                existing.firstVisit = min(existing.firstVisit, cluster.firstVisit)
                existing.lastVisit = max(existing.lastVisit, cluster.lastVisit)
                existing.clusterCount += 1
                byName[name] = existing
            } else {
                byName[name] = MergedPhotoPlace(
                    name: name,
                    category: cluster.category,
                    photoCount: cluster.photoCount,
                    firstVisit: cluster.firstVisit,
                    lastVisit: cluster.lastVisit,
                    clusterCount: 1
                )
            }
        }
        return byName.values.sorted { $0.photoCount > $1.photoCount }
    }

    private var unmatchedCount: Int {
        nonHome.count - matchedRaw.count
    }

    private var tags: [InterestVectorManager.TagWeight] {
        let total = Float(nonHome.count)
        guard total > 0 else { return [] }
        var results: [InterestVectorManager.TagWeight] = []
        if !matchedRaw.isEmpty {
            results.append(.init(tag: "\(matched.count) places found", weight: Float(matchedRaw.count) / total))
        }
        if unmatchedCount > 0 {
            results.append(.init(tag: "\(unmatchedCount) no match", weight: Float(unmatchedCount) / total))
        }
        return results
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Donut at top
                    if !tags.isEmpty {
                        DonutChartView(tags: tags, size: 80, lineWidth: 18)
                            .padding(20)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    // Stats
                    HStack(spacing: 0) {
                        statBubble(value: "\(photosManager.metrics?.totalPhotos ?? UserDefaults.standard.integer(forKey: "photos_total_count"))", label: "Photos scanned", color: .orange)
                        statBubble(value: "\(nonHome.count)", label: "Locations", color: .blue)
                        statBubble(value: "\(matched.count)", label: "Places found", color: .green)
                    }
                    .padding(16)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    // Matched places list
                    if !matched.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Places Found")
                                .font(.headline)
                                .padding(.horizontal, 4)

                            ForEach(matched) { place in
                                HStack(spacing: 12) {
                                    Image(systemName: place.category.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(Color.green.gradient)
                                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.name)
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                            .lineLimit(1)

                                        HStack(spacing: 8) {
                                            Text(place.category.displayName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text("\(place.photoCount) photos")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(place.firstVisit, style: .date)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        if place.lastVisit.timeIntervalSince(place.firstVisit) > 86400 {
                                            Text(place.lastVisit, style: .date)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color(UIColor.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    // Unmatched summary
                    if unmatchedCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unmatched Locations")
                                .font(.headline)
                                .padding(.horizontal, 4)

                            Text("\(unmatchedCount) photo locations couldn't be matched to a known place. These are typically residential areas, streets, or locations without a named business nearby.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Photo Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statBubble(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
