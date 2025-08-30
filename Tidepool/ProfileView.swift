import SwiftUI
import MapKit
import Photos

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("photos_opt_in") private var photosOptIn: Bool = false
    @AppStorage("background_enabled") private var backgroundEnabled: Bool = false
    @AppStorage("reduced_accuracy") private var reducedAccuracy: Bool = true

    @StateObject private var location = LocationManager()
    @StateObject private var appleMapsManager = AppleMapsIntegrationManager()
    @StateObject private var photosManager = PhotosIntegrationManager()
    @StateObject private var favoritesManager = InAppFavoritesManager()
    @State private var vectorManager: InterestVectorManager?
    @State private var showingHomePicker = false
    @State private var photosDeniedAlert = false
    @State private var showingLocationImport = false
    @State private var showingFavorites = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Location")) {
                    HStack {
                        Label("Location Permission", systemImage: "location")
                        Spacer()
                        Button("When In Use") { location.requestAuthorization() }
                            .buttonStyle(.bordered)
                        Button("Always") { location.requestAlwaysAuthorization() }
                            .buttonStyle(.bordered)
                    }
                    Toggle(isOn: $backgroundEnabled) {
                        Label("Background updates (visits & significant-change)", systemImage: "waveform.path.ecg")
                    }
                    .onChange(of: backgroundEnabled) { _, enabled in
                        location.setBackgroundUpdatesEnabled(enabled)
                    }
                    Toggle(isOn: $reducedAccuracy) {
                        Label("Reduced accuracy (battery)", systemImage: "bolt.slash")
                    }
                    .onChange(of: reducedAccuracy) { _, reduced in
                        location.applyReducedAccuracy(reduced)
                    }
                    HStack {
                        Label("Home" , systemImage: "house")
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

                Section(header: Text("Integrations")) {
                    HStack {
                        Label("Spotify", systemImage: "music.note")
                        Spacer()
                        Button("Connect") {
                            // TODO: Implement Spotify OAuth
                        }
                        .buttonStyle(.bordered)
                    }
                    HStack {
                        Label("Instagram", systemImage: "camera")
                        Spacer()
                        Button("Connect") {
                            // TODO: Implement Instagram OAuth
                        }
                        .buttonStyle(.bordered)
                    }
                    // Photos Integration
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
                        } else {
                            Button("Connect") {
                                connectPhotos()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    
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
                
                // Interest Profile Section
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
                
                // Favorites Section
                Section(header: Text("Favorites")) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("My Favorites", systemImage: "heart.fill")
                                .foregroundStyle(.red)
                            Spacer()
                            Button("View All") {
                                showingFavorites = true
                            }
                            .buttonStyle(.bordered)
                        }
                        
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
                }

                Section(header: Text("Privacy"), footer: Text("We never show your exact location or identity to others. Presence near Home (within 500 ft) is never shared.")) {
                    Label("Anonymous presence only", systemImage: "shield.lefthalf.filled")
                    Label("K-anonymity & DP on aggregates", systemImage: "checkerboard.shield")
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("Layers")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        HapticFeedbackManager.shared.impact(.light)
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                }
            }
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
            .alert("Photos Access Required", isPresented: $photosDeniedAlert, actions: {
                Button("Cancel", role: .cancel) {}
                Button("Open Settings") {
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
            }, message: {
                Text("Tidepool needs access to your Photos to discover your favorite places from photo locations. Enable Photos access in Settings to connect.")
            })
            .onAppear {
                location.setBackgroundUpdatesEnabled(backgroundEnabled)
                location.applyReducedAccuracy(reducedAccuracy)
                
                // Initialize vector manager if not already initialized
                if vectorManager == nil {
                    vectorManager = InterestVectorManager(
                        appleMapsManager: appleMapsManager,
                        photosManager: photosManager,
                        favoritesManager: favoritesManager
                    )
                }
            }
            .onChange(of: appleMapsManager.savedLocations) { _, _ in
                vectorManager?.computeVector()
            }
            .onChange(of: photosManager.clusters) { _, _ in
                vectorManager?.computeVector()
            }
            .onChange(of: favoritesManager.favorites) { _, _ in
                vectorManager?.computeVector()
            }
        }
    }

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

#Preview {
    ProfileView()
} 