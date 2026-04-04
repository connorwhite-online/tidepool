import SwiftUI
import MapKit
import CoreLocation

// MARK: - Location Detail Data Model

struct LocationDetail: Identifiable {
    let id = UUID()
    let name: String
    let category: PlaceCategory
    let coordinate: CLLocationCoordinate2D
    let address: String?
    let phoneNumber: String?
    let website: String?
    let hours: BusinessHours?
    let images: [LocationImage]
    let rating: Double?
    let priceLevel: PriceLevel?
    let amenities: [String]
    let userFavoriteStatus: FavoriteStatus
    
    enum PriceLevel: String, CaseIterable {
        case budget = "$"
        case moderate = "$$"
        case expensive = "$$$"
        case luxury = "$$$$"
    }
    
    enum FavoriteStatus {
        case notFavorited
        case favorited(rating: Int, notes: String?)
    }
}

struct BusinessHours {
    let periods: [Period]
    let isOpenNow: Bool
    
    struct Period {
        let open: Time
        let close: Time
        let day: Weekday
    }
    
    struct Time {
        let hour: Int
        let minute: Int
        
        var formatted: String {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
            return formatter.string(from: date)
        }
    }
    
    enum Weekday: Int, CaseIterable {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
        
        var name: String {
            Calendar.current.weekdaySymbols[rawValue - 1]
        }
    }
}

struct LocationImage {
    let url: URL
    let caption: String?
    let aspectRatio: Double
}

// MARK: - Location Detail Floating Modal

struct LocationDetailModal: View {
    @Binding var selectedLocation: LocationDetail?
    @ObservedObject var favoritesManager: InAppFavoritesManager

    @State private var dragOffset: CGFloat = 0

    private var isPresented: Bool { selectedLocation != nil }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dimmed backdrop
            Color.black.opacity(isPresented ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .allowsHitTesting(isPresented)

            // Modal card
            if let location = selectedLocation {
                LocationDetailContent(
                    location: location,
                    favoritesManager: favoritesManager,
                    onDismiss: { dismiss() }
                )
                .background(Color(UIColor.systemBackground))
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 40,
                    bottomLeadingRadius: 60,
                    bottomTrailingRadius: 60,
                    topTrailingRadius: 40,
                    style: .continuous
                ))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .offset(y: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 120 {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    dragOffset = 0
                                }
                            } else {
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isPresented)
        .ignoresSafeArea(edges: .bottom)
    }

    private func dismiss() {
        selectedLocation = nil
        HapticFeedbackManager.shared.selection()
    }
}

// MARK: - Location Detail Content

private struct LocationDetailContent: View {
    let location: LocationDetail
    @ObservedObject var favoritesManager: InAppFavoritesManager
    let onDismiss: () -> Void

    @State private var enrichment: YelpEnrichmentManager.YelpEnrichment?
    @State private var isLoadingEnrichment = false

    private var stablePlaceId: String {
        FavoriteLocation.stablePlaceId(name: location.name, coordinate: location.coordinate)
    }

    private var isFavorited: Bool {
        favoritesManager.isFavorited(stablePlaceId)
    }

    private var displayRating: Double? {
        enrichment?.rating ?? location.rating
    }

    private var displayPrice: LocationDetail.PriceLevel? {
        enrichment?.price ?? location.priceLevel
    }

    private var displayIsOpen: Bool? {
        enrichment?.isOpenNow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)

            // Photos carousel (from Yelp)
            if let photos = enrichment?.photos, !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos.prefix(5), id: \.url) { photo in
                            AsyncImage(url: photo.url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 140, height: 100)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                case .failure:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.quaternary)
                                        .frame(width: 140, height: 100)
                                default:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.quaternary)
                                        .frame(width: 140, height: 100)
                                        .overlay(ProgressView().tint(.secondary))
                                }
                            }
                        }
                    }
                }
                .frame(height: 100)
            }

            // Name + category + star
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(location.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Image(systemName: location.category.iconName)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(location.category.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        // Rating + Price + Open status
                        if let rating = displayRating {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let price = displayPrice {
                            Text(price.rawValue)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        if let isOpen = displayIsOpen {
                            Text(isOpen ? "Open" : "Closed")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(isOpen ? .green : .red)
                        }

                        if let address = location.address {
                            if displayIsOpen != nil {
                                Text("·")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorited ? "star.fill" : "star")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundStyle(isFavorited ? .yellow : .secondary)
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // Action row
            HStack(spacing: 10) {
                Button {
                    openInMaps()
                } label: {
                    Label {
                        Text("Directions")
                            .fontWeight(.medium)
                    } icon: {
                        Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    shareLocation()
                } label: {
                    Label {
                        Text("Share")
                            .fontWeight(.medium)
                    } icon: {
                        Image(systemName: "square.and.arrow.up.fill")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .task {
            guard !isLoadingEnrichment else { return }
            isLoadingEnrichment = true
            enrichment = await YelpEnrichmentManager.shared.enrich(
                name: location.name,
                coordinate: location.coordinate
            )
            isLoadingEnrichment = false
        }
    }

    private func toggleFavorite() {
        if isFavorited {
            favoritesManager.removeFavorite(for: stablePlaceId)
        } else {
            favoritesManager.quickFavorite(
                name: location.name,
                category: location.category,
                coordinate: location.coordinate
            )
        }
        HapticFeedbackManager.shared.impact(.light)
    }

    private func openInMaps() {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        mapItem.name = location.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }

    private func shareLocation() {
        let shareText = "\(location.name)\n\(location.address ?? "")"
        let activityController = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityController, animated: true)
        }
    }
}
