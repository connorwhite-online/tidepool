import SwiftUI
import MapKit

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("has_onboarded") private var hasOnboarded: Bool = false
    @ObservedObject private var location = LocationManager.shared
    @State private var showingHomePicker = false

    private var locationGranted: Bool {
        location.authorizationStatus == .authorizedWhenInUse
            || location.authorizationStatus == .authorizedAlways
    }

    private var locationDenied: Bool {
        location.authorizationStatus == .denied
            || location.authorizationStatus == .restricted
    }

    private var homeSet: Bool { location.homeLocation != nil }

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
                        if !locationGranted { location.requestAuthorization() }
                    } label: {
                        HStack {
                            Image(systemName: locationGranted ? "checkmark.circle.fill" : "location.fill")
                            Text(locationGranted ? "Location enabled"
                                 : locationDenied ? "Location denied — enable in Settings"
                                 : "Enable Location")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(locationGranted ? .green : .accentColor)
                    .disabled(locationGranted)

                    Button {
                        showingHomePicker = true
                    } label: {
                        HStack {
                            Image(systemName: homeSet ? "checkmark.circle.fill" : "house.fill")
                            Text(homeSet ? "Home set — tap to update" : "Set Home")
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(homeSet ? .green : .accentColor)
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
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                // Both steps should be addressed before continuing. If the user
                // denied location at the system prompt, allow them through with
                // home set so we have at least one anchor for the map view.
                .disabled(!(locationGranted || locationDenied) || !homeSet)

                Text("You can change Home later in Profile.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingHomePicker) {
                SimpleHomePicker(current: location.homeLocation) { coord, _ in
                    location.setHome(to: coord)
                }
            }
        }
    }
}

#Preview {
    OnboardingView()
} 