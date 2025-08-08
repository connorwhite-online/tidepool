import SwiftUI
import MapKit

struct ProfileView: View {
    @AppStorage("photos_opt_in") private var photosOptIn: Bool = false
    @StateObject private var location = LocationManager()
    @State private var showingHomePicker = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Location")) {
                    HStack {
                        Label("Location Permission", systemImage: "location")
                        Spacer()
                        Button("Request") { location.requestAuthorization() }
                            .buttonStyle(.bordered)
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
                        Button("Connect") {}
                            .buttonStyle(.bordered)
                    }
                    HStack {
                        Label("Instagram", systemImage: "camera")
                        Spacer()
                        Button("Connect") {}
                            .buttonStyle(.bordered)
                    }
                    Toggle(isOn: $photosOptIn) {
                        Label("Use Photos location tags", systemImage: "photo")
                    }
                }

                Section(header: Text("Privacy"), footer: Text("We never show your exact location or identity to others. Presence near Home (within 500 ft) is never shared.")) {
                    Label("Anonymous presence only", systemImage: "shield.lefthalf.filled")
                    Label("K-anonymity & DP on aggregates", systemImage: "checkerboard.shield")
                }

                Section(header: Text("Data")) {
                    Button("Export My Data") {}
                    Button(role: .destructive) { } label: {
                        Text("Delete My Data")
                    }
                }
            }
            .navigationTitle("Profile")
            .sheet(isPresented: $showingHomePicker) {
                SimpleHomePicker(current: location.homeLocation) { coord in
                    location.setHome(to: coord)
                }
            }
        }
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