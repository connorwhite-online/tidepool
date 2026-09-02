import SwiftUI
import MapKit
import TidepoolShared

// MARK: - My Lists carousel (search sheet)

struct MyListsCarouselSection: View {
    @ObservedObject var listsManager: MyListsManager
    let userLocation: CLLocationCoordinate2D
    let onSelectPlace: (MyListPlace) -> Void

    var body: some View {
        if listsManager.isLoading && listsManager.lists.isEmpty {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.6)
                Text("Building your lists...")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        } else if !listsManager.lists.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(listsManager.lists, id: \.category) { list in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: list.category.iconName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(list.category.displayName)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                            Text("· \(list.places.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(list.places, id: \.placeId) { place in
                                    MyListPlaceCard(place: place, userLocation: userLocation) {
                                        onSelectPlace(place)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
    }
}

private struct MyListPlaceCard: View {
    let place: MyListPlace
    let userLocation: CLLocationCoordinate2D
    let onTap: () -> Void

    private var categoryIcon: String {
        PlaceCategory(rawValue: place.category.rawValue)?.iconName ?? "mappin"
    }

    private var distanceString: String {
        let user = CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude)
        let loc = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let meters = loc.distance(from: user)
        if meters < 1609 {
            return "\(Int(meters * 3.281)) ft"
        }
        return String(format: "%.1f mi", meters / 1609.34)
    }

    private var visitLabel: String {
        if place.isExplicitFavorite && place.visitCount <= 1 {
            return "★ saved"
        }
        return "\(place.visitCount)× visited"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: categoryIcon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if place.visitCount >= 2 {
                        Text("\(place.visitCount)×")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                }

                Text(place.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(visitLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(distanceString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 130, alignment: .leading)
            .padding(12)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile summary card

struct MyListsProfileCard: View {
    @ObservedObject var listsManager: MyListsManager
    let onTap: () -> Void

    private var totalPlaces: Int {
        listsManager.response?.meta.placeCount ?? 0
    }

    private var topCategories: [MyListCategory] {
        listsManager.lists.prefix(3).map(\.category)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("My Lists")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)

                    if totalPlaces > 0 {
                        Text("\(totalPlaces) places near you")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if listsManager.isLoading {
                        Text("Compiling from your visits...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Visit places twice to auto-add")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if !topCategories.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(topCategories, id: \.self) { cat in
                            Image(systemName: cat.iconName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
    }
}

// MARK: - Full lists sheet

struct MyListsSheet: View {
    @ObservedObject var listsManager: MyListsManager
    let userLocation: CLLocationCoordinate2D
    let onSelectPlace: (MyListPlace) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MyListsCarouselSection(
                    listsManager: listsManager,
                    userLocation: userLocation,
                    onSelectPlace: { place in
                        onSelectPlace(place)
                        dismiss()
                    }
                )
                .padding(.top, 8)

                if listsManager.lists.isEmpty && !listsManager.isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "list.star")
                            .font(.largeTitle)
                            .foregroundStyle(.quaternary)
                        Text("No lists yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Places you visit twice within 10 miles appear here automatically.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.top, 40)
                }
            }
            .navigationTitle("My Lists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
