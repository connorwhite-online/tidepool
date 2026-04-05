import SwiftUI
import MapKit
import Photos
import Combine

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
                favoritesManager: favoritesManager
            ))
    }

    @ViewBuilder
    private var formContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                integrationsCard
                interestProfileCard
                favoritesCard
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

            // Integration pills
            VStack(spacing: 10) {
                // Birthday
                integrationPill(icon: "birthday.cake.fill", title: "Birthday", tint: .pink) {
                    if ageRangeManager.isAuthorized {
                        Button {
                            tempBirthday = ageRangeManager.birthday ?? Date()
                            showingBirthdayPicker = true
                        } label: {
                            connectedBadge(text: ageRangeManager.displayAge)
                        }
                        .buttonStyle(.plain)
                    } else {
                        connectButton { tempBirthday = Calendar.current.date(byAdding: .year, value: -25, to: Date()) ?? Date(); showingBirthdayPicker = true }
                    }
                }

                // Spotify
                integrationPill(icon: "waveform", title: "Spotify", tint: .green) {
                    if spotifyManager.isConnected && spotifyManager.isSyncing {
                        syncingBadge
                    } else if spotifyManager.isConnected {
                        connectedMenu(
                            summary: spotifyManager.getSummary(),
                            onRefresh: { Task { await spotifyManager.refreshData() } },
                            onDisconnect: { spotifyManager.disconnect() }
                        )
                    } else {
                        connectButton { Task { await spotifyManager.authenticate() } }
                    }
                }

                // Apple Music
                integrationPill(icon: "music.note", title: "Apple Music", tint: .red) {
                    if appleMusicManager.isAuthorized && appleMusicManager.isSyncing {
                        syncingBadge
                    } else if appleMusicManager.isAuthorized {
                        connectedMenu(
                            summary: appleMusicManager.getSummary(),
                            onRefresh: { Task { await appleMusicManager.refreshData() } },
                            onDisconnect: { appleMusicManager.disconnect() }
                        )
                    } else {
                        connectButton { Task { await appleMusicManager.requestAuthorization() } }
                    }
                }

                // Photos
                integrationPill(icon: "photo.fill", title: "Photos", tint: .orange) {
                    if photosManager.isEnabled && photosManager.isProcessing {
                        syncingBadge
                    } else if photosManager.isEnabled {
                        connectedMenu(
                            summary: photosManager.getPlacesSummary(),
                            onRefresh: { Task { await photosManager.refreshData() } },
                            onDisconnect: { disconnectPhotos() }
                        )
                    } else {
                        connectButton { connectPhotos() }
                    }
                }
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

    private func connectButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    private func connectedMenu(summary: String?, onRefresh: @escaping () -> Void, onDisconnect: @escaping () -> Void) -> some View {
        Menu {
            Button { onRefresh() } label: {
                Label("Refresh Data", systemImage: "arrow.clockwise")
            }
            Divider()
            Button(role: .destructive) { onDisconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        } label: {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let summary {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func connectedBadge(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .foregroundStyle(.green)
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

                locationSettingRow(icon: "house.fill", title: "Home", tint: .orange) {
                    Button(location.homeLocation == nil ? "Set" : "Update") { showingHomePicker = true }
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .indigo.opacity(0.06), radius: 12, y: 4)
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
    @State private var centerCoordinate: CLLocationCoordinate2D
    let onSelect: (CLLocationCoordinate2D) -> Void

    init(current: CLLocationCoordinate2D?, onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        self.onSelect = onSelect
        _centerCoordinate = State(initialValue: current ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194))
    }

    var body: some View {
        let initialRegion = MKCoordinateRegion(
            center: centerCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        return VStack(spacing: 0) {
            HomePickerMapRepresentable(centerCoordinate: $centerCoordinate, initialRegion: initialRegion)
                .overlay(alignment: .center) {
                    Image(systemName: "house.fill")
                        .font(.title)
                        .foregroundColor(.red)
                        .shadow(radius: 3)
                }
                .ignoresSafeArea()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Set Home Here") {
                    onSelect(centerCoordinate)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial)
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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingHomePicker) {
                SimpleHomePicker(current: location.homeLocation) { coord in
                    location.setHome(to: coord)
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

#Preview {
    ProfileView()
        .environmentObject(InAppFavoritesManager())
}
