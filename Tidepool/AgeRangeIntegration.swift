import Foundation
import SwiftUI

// MARK: - Age Manager

@MainActor
class AgeRangeManager: ObservableObject {
    @Published var birthday: Date?
    @Published var isAuthorized: Bool = false

    private let userDefaults = UserDefaults.standard
    private let birthdayKey = "user_birthday"

    init() {
        loadCachedData()
    }

    // MARK: - Computed Properties

    var age: Int? {
        guard let birthday = birthday else { return nil }
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthday, to: Date())
        return ageComponents.year
    }

    var ageRange: UserAgeRange {
        guard let age = age else { return .unknown }
        if age < 18 {
            return .under18
        } else if age < 21 {
            return .eighteenTo20
        } else {
            return .twentyOnePlus
        }
    }

    var displayAge: String {
        guard let age = age else { return "Not set" }
        return "\(age) years old"
    }

    var canAccessAlcoholVenues: Bool {
        guard let age = age else { return false }
        return age >= 21
    }

    var canAccessAdultVenues: Bool {
        guard let age = age else { return false }
        return age >= 18
    }

    // MARK: - Public Methods

    func setBirthday(_ date: Date) {
        self.birthday = date
        self.isAuthorized = true
        saveCachedData()
        HapticFeedbackManager.shared.notification(.success)
    }

    func reset() {
        birthday = nil
        isAuthorized = false
        clearCachedData()
        HapticFeedbackManager.shared.impact(.light)
    }

    // MARK: - Interest Tags

    func getInterestTags() -> [String: Int] {
        var tags: [String: Int] = [:]

        switch ageRange {
        case .under18:
            tags["family_friendly"] = 5
            tags["all_ages"] = 5
            tags["nightlife"] = -10
            tags["bar"] = -10

        case .eighteenTo20:
            tags["all_ages"] = 3
            tags["nightlife"] = 2
            tags["bar"] = -5

        case .twentyOnePlus:
            tags["nightlife"] = 3
            tags["bar"] = 2
            tags["wine_bar"] = 2
            tags["craft_beer"] = 2
            tags["cocktails"] = 2

        case .unknown:
            break
        }

        return tags
    }

    // MARK: - Venue Filtering

    func shouldShowVenue(withTags tags: [String]) -> Bool {
        let adultOnlyTags = ["bar", "nightclub", "wine_bar", "brewery", "cocktail_lounge"]
        let hasAdultContent = tags.contains { adultOnlyTags.contains($0) }

        if hasAdultContent && !canAccessAlcoholVenues {
            return false
        }

        return true
    }

    func venueAgeWarning(forTags tags: [String]) -> String? {
        let adultOnlyTags = ["bar", "nightclub", "wine_bar", "brewery", "cocktail_lounge"]
        let hasAdultContent = tags.contains { adultOnlyTags.contains($0) }

        if hasAdultContent {
            switch ageRange {
            case .under18:
                return "This venue may be 21+ only"
            case .eighteenTo20:
                return "This venue may require ID (21+)"
            case .twentyOnePlus, .unknown:
                return nil
            }
        }

        return nil
    }

    // MARK: - Private Methods

    private func saveCachedData() {
        userDefaults.set(birthday, forKey: birthdayKey)
    }

    private func loadCachedData() {
        if let savedBirthday = userDefaults.object(forKey: birthdayKey) as? Date {
            birthday = savedBirthday
            isAuthorized = true
        }
    }

    private func clearCachedData() {
        userDefaults.removeObject(forKey: birthdayKey)
    }
}

// MARK: - Age Range Enum (for compatibility)

enum UserAgeRange: String, Codable {
    case under18 = "under_18"
    case eighteenTo20 = "18_to_20"
    case twentyOnePlus = "21_plus"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .under18: return "Under 18"
        case .eighteenTo20: return "18-20"
        case .twentyOnePlus: return "21+"
        case .unknown: return "Not set"
        }
    }
}
