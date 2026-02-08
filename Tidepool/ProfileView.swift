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
    @StateObject private var favoritesManager = InAppFavoritesManager()
    @StateObject private var spotifyManager = SpotifyIntegrationManager()
    @StateObject private var appleMusicManager = AppleMusicIntegrationManager()
    @StateObject private var ageRangeManager = AgeRangeManager()

    @State private var vectorManager: InterestVectorManager?
    @State private var showingHomePicker = false
    @State private var photosDeniedAlert = false
    @State private var showingLocationImport = false
    @State private var showingFavorites = false
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
                photosDeniedAlert: $photosDeniedAlert,
                location: location,
                appleMapsManager: appleMapsManager,
                favoritesManager: favoritesManager
            ))
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            locationSection
            integrationsSection
            interestProfileSection
            favoritesSection
            privacySection
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
                spotifyManager.disconnect()
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
}
