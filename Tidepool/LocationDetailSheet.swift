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

// MARK: - Location Detail Sheet

struct LocationDetailSheet: View {
    let location: LocationDetail
    let originPoint: CGPoint
    @Binding var isPresented: Bool
    @ObservedObject var favoritesManager: InAppFavoritesManager
    
    @State private var selectedImageIndex = 0
    @State private var showingFullHours = false
    @State private var showingFavoriteSheet = false
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background overlay
                Color.black
                    .opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissSheet()
                    }
                
                // Main sheet content
                VStack(spacing: 0) {
                    Spacer()
                    
                    sheetContent
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 16)
                }
            }
        }
        .originBasedTransition(from: originPoint, physics: .gentle)
        .reducedMotionAlternative {
            // Simplified transition for reduced motion
            Color.black.opacity(0.4).ignoresSafeArea()
                .overlay(sheetContent.padding())
        }
    }
    
    private var sheetContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with image carousel
                headerSection
                
                // Basic info section
                basicInfoSection
                
                // Hours section
                if let hours = location.hours {
                    hoursSection(hours)
                }
                
                // Contact section
                contactSection
                
                // Amenities section
                if !location.amenities.isEmpty {
                    amenitiesSection
                }
                
                // Action buttons
                actionButtonsSection
                
                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .frame(maxHeight: UIScreen.main.bounds.height * 0.75)
    }
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Drag indicator
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            
            // Image carousel
            if !location.images.isEmpty {
                TabView(selection: $selectedImageIndex) {
                    ForEach(location.images.indices, id: \.self) { index in
                        AsyncImage(url: location.images[index].url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle()
                                .fill(.quaternary)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                )
                        }
                        .frame(height: 200)
                        .clipped()
                        .tag(index)
                    }
                }
                .frame(height: 200)
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Title and category
            VStack(alignment: .leading, spacing: 4) {
                Text(location.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Image(systemName: location.category.iconName)
                        .foregroundStyle(.secondary)
                    Text(location.category.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let rating = location.rating {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.caption)
                            Text(String(format: "%.1f", rating))
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                    
                    if let priceLevel = location.priceLevel {
                        Text(priceLevel.rawValue)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    
    private var basicInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let address = location.address {
                Label {
                    Text(address)
                        .font(.subheadline)
                } icon: {
                    Image(systemName: "location")
                        .foregroundStyle(.secondary)
                }
            }
            
            // Distance from user (if available)
            // This would be calculated based on user's current location
            Label {
                Text("0.3 mi away")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "figure.walk")
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func hoursSection(_ hours: BusinessHours) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text("Hours")
                        .font(.headline)
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                Button {
                    withAnimation(SpringPhysics.standard.swiftUISpring) {
                        showingFullHours.toggle()
                    }
                } label: {
                    Image(systemName: showingFullHours ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Current status
            HStack {
                Circle()
                    .fill(hours.isOpenNow ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(hours.isOpenNow ? "Open now" : "Closed")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(hours.isOpenNow ? .green : .red)
            }
            
            if showingFullHours {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(BusinessHours.Weekday.allCases, id: \.self) { day in
                        let todaysPeriods = hours.periods.filter { $0.day == day }
                        HStack {
                            Text(day.name)
                                .font(.caption)
                                .frame(width: 80, alignment: .leading)
                            
                            if todaysPeriods.isEmpty {
                                Text("Closed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(todaysPeriods.indices, id: \.self) { index in
                                        let period = todaysPeriods[index]
                                        Text("\(period.open.formatted) - \(period.close.formatted)")
                                            .font(.caption)
                                    }
                                }
                            }
                            
                            Spacer()
                        }
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }
    
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let phone = location.phoneNumber {
                Button {
                    if let url = URL(string: "tel:\(phone)") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label {
                        Text(phone)
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "phone")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
            
            if let website = location.website {
                Button {
                    if let url = URL(string: website) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label {
                        Text("Website")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "safari")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var amenitiesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Amenities")
                .font(.headline)
            
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                ForEach(location.amenities, id: \.self) { amenity in
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(amenity)
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
    
    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Directions button
                Button {
                    openInMaps()
                } label: {
                    Label("Directions", systemImage: "location.north")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                // Share button
                Button {
                    shareLocation()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            
            // Favorite button
            Button {
                favoriteLocation()
            } label: {
                HStack {
                    Image(systemName: isFavorited ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorited ? .red : .primary)
                    Text(isFavorited ? "Favorited" : "Add to Favorites")
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .satisfyingSpring(isActive: isFavorited)
            .sheet(isPresented: $showingFavoriteSheet) {
                FavoriteLocationSheet(
                    location: location,
                    favoritesManager: favoritesManager,
                    isPresented: $showingFavoriteSheet
                )
            }
        }
    }
    
    private var isFavorited: Bool {
        if case .favorited = location.userFavoriteStatus {
            return true
        }
        return false
    }
    
    private func dismissSheet() {
        withAnimation(SpringPhysics.gentle.swiftUISpring) {
            isPresented = false
        }
        
        HapticFeedbackManager.shared.selection()
    }
    
    private func favoriteLocation() {
        if isFavorited {
            // Remove from favorites
            favoritesManager.removeFavorite(for: location.id.uuidString)
        } else {
            // Add to favorites
            showingFavoriteSheet = true
        }
        
        HapticFeedbackManager.shared.impact(.light)
    }
    
    private func openInMaps() {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        mapItem.name = location.name
        mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
        
        HapticFeedbackManager.shared.selection()
    }
    
    private func shareLocation() {
        let shareText = "\(location.name)\n\(location.address ?? "")"
        let activityController = UIActivityViewController(activityItems: [shareText], applicationActivities: nil)
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(activityController, animated: true)
        }
        
        HapticFeedbackManager.shared.selection()
    }
}

// MARK: - Favorite Location Sheet

struct FavoriteLocationSheet: View {
    let location: LocationDetail
    @ObservedObject var favoritesManager: InAppFavoritesManager
    @Binding var isPresented: Bool
    
    @State private var rating: Int = 5
    @State private var notes: String = ""
    @State private var selectedTags: Set<String> = []
    
    private let availableTags = ["Great food", "Good service", "Nice atmosphere", "Good value", "Convenient location", "Would return"]
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add to Favorites")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text(location.name)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                
                // Rating
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rating")
                        .font(.headline)
                    
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                withAnimation(SpringPhysics.snappy.swiftUISpring) {
                                    rating = star
                                }
                                HapticFeedbackManager.shared.selection()
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundStyle(star <= rating ? .yellow : .secondary)
                            }
                            .satisfyingSpring(isActive: star == rating)
                        }
                    }
                }
                
                // Tags
                VStack(alignment: .leading, spacing: 8) {
                    Text("What did you like?")
                        .font(.headline)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 8) {
                        ForEach(availableTags, id: \.self) { tag in
                            Button {
                                withAnimation(SpringPhysics.standard.swiftUISpring) {
                                    if selectedTags.contains(tag) {
                                        selectedTags.remove(tag)
                                    } else {
                                        selectedTags.insert(tag)
                                    }
                                }
                                HapticFeedbackManager.shared.selection()
                            } label: {
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(selectedTags.contains(tag) ? Color.blue : Color(UIColor.quaternarySystemFill))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(selectedTags.contains(tag) ? .white : .primary)
                            }
                        }
                    }
                }
                
                // Notes
                VStack(alignment: .leading, spacing: 8) {
                    Text("Notes (optional)")
                        .font(.headline)
                    
                    TextField("Add any notes about this place...", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...6)
                }
                
                Spacer()
                
                // Save button
                Button {
                    saveFavorite()
                } label: {
                    Text("Save to Favorites")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    private func saveFavorite() {
        let favoriteNotes = notes.isEmpty ? selectedTags.joined(separator: ", ") : "\(selectedTags.joined(separator: ", "))\n\(notes)"
        
        favoritesManager.addFavorite(
            placeId: location.id.uuidString,
            name: location.name,
            category: location.category,
            coordinate: location.coordinate,
            rating: rating,
            notes: favoriteNotes.isEmpty ? nil : favoriteNotes
        )
        
        HapticFeedbackManager.shared.notification(.success)
        isPresented = false
    }
}

#Preview {
    LocationDetailSheet(
        location: LocationDetail(
            name: "Blue Bottle Coffee",
            category: .cafe,
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            address: "66 Mint St, San Francisco, CA 94103",
            phoneNumber: "(415) 495-3394",
            website: "https://bluebottlecoffee.com",
            hours: BusinessHours(
                periods: [
                    BusinessHours.Period(
                        open: BusinessHours.Time(hour: 7, minute: 0),
                        close: BusinessHours.Time(hour: 19, minute: 0),
                        day: .monday
                    )
                ],
                isOpenNow: true
            ),
            images: [],
            rating: 4.5,
            priceLevel: .moderate,
            amenities: ["WiFi", "Outdoor seating", "Accepts credit cards"],
            userFavoriteStatus: .notFavorited
        ),
        originPoint: CGPoint(x: 200, y: 400),
        isPresented: .constant(true),
        favoritesManager: InAppFavoritesManager()
    )
}
