import SwiftUI
import MapKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("has_onboarded") private var hasOnboarded: Bool = false
    @StateObject private var location = LocationManager()
    @State private var showingHomePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Text("Welcome to Tidepool")
                    .font(.largeTitle.bold())
                Text("Anonymous interest heatmaps. We never share your precise location or identity.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    Button {
                        location.requestAuthorization()
                    } label: {
                        Label("Enable Location", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        showingHomePicker = true
                    } label: {
                        Label(location.homeLocation == nil ? "Set Home" : "Update Home", systemImage: "house.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    hasOnboarded = true
                    dismiss()
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
                .disabled(location.authorizationStatus == .notDetermined && location.homeLocation == nil)

                Text("You can change Home later in Profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingHomePicker) {
                SimpleHomePicker(current: location.homeLocation) { coord in
                    location.setHome(to: coord)
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
} 