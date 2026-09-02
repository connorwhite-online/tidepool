import XCTest
@testable import TidepoolShared

final class MyListsEngineTests: XCTestCase {

    private let center = Coordinate(latitude: 34.0522, longitude: -118.2437)

    func testGeoDistanceZero() {
        let d = Geo.distanceMeters(from: center, to: center)
        XCTAssertEqual(d, 0, accuracy: 0.01)
    }

    func testMultipleVisitsBoostScore() {
        let one = makeSignal(visitCount: 1, category: .cafe, hours: [8])
        let three = makeSignal(visitCount: 3, category: .cafe, hours: [8], name: "Daily Brew")
        let s1 = MyListsEngine.rankScore(for: one, referenceDate: Date())
        let s3 = MyListsEngine.rankScore(for: three, referenceDate: Date())
        XCTAssertGreaterThan(s3, s1)
    }

    func testExplicitFavoriteQualifiesWithSingleVisit() {
        let signal = makeSignal(
            visitCount: 1,
            category: .restaurant,
            hours: [12],
            isFavorite: true
        )
        let response = MyListsEngine.compile(
            signals: [signal],
            options: MyListsCompileOptions(center: center, radiusMiles: 10)
        )
        XCTAssertFalse(response.lists.isEmpty)
        XCTAssertEqual(response.meta.placeCount, 1)
    }

    func testRequiresTwoVisitsWithoutFavorite() {
        let signal = makeSignal(visitCount: 1, category: .cafe, hours: [8])
        let response = MyListsEngine.compile(
            signals: [signal],
            options: MyListsCompileOptions(center: center, radiusMiles: 10)
        )
        XCTAssertTrue(response.lists.isEmpty)
        XCTAssertEqual(response.meta.placeCount, 0)
    }

    func testCoffeeCategoryFromCafeVisits() {
        let signal = makeSignal(visitCount: 3, category: .cafe, hours: [8, 9])
        let response = MyListsEngine.compile(
            signals: [signal],
            options: MyListsCompileOptions(center: center, radiusMiles: 10)
        )
        let coffee = response.lists.first { $0.category == .coffee }
        XCTAssertNotNil(coffee)
        XCTAssertEqual(coffee?.places.first?.name, signal.name)
    }

    func testRadiusFilterExcludesDistantPlaces() {
        let near = makeSignal(visitCount: 3, category: .cafe, hours: [8], lat: center.latitude, lng: center.longitude)
        let far = makeSignal(
            visitCount: 5,
            category: .cafe,
            hours: [8],
            name: "Far Cafe",
            lat: 40.7128,
            lng: -74.0060
        )
        let response = MyListsEngine.compile(
            signals: [near, far],
            options: MyListsCompileOptions(center: center, radiusMiles: 10)
        )
        XCTAssertEqual(response.meta.placeCount, 1)
        XCTAssertEqual(response.meta.localeRankings.first?.name, near.name)
    }

    func testLocaleRankingsSortedByScore() {
        let weak = makeSignal(visitCount: 2, category: .cafe, hours: [8], name: "Occasional")
        let strong = makeSignal(visitCount: 6, category: .cafe, hours: [8, 9], name: "Regular")
        let response = MyListsEngine.compile(
            signals: [weak, strong],
            options: MyListsCompileOptions(center: center, radiusMiles: 10)
        )
        XCTAssertEqual(response.meta.localeRankings.first?.name, "Regular")
    }

    func testLateNightFromBarHours() {
        let signal = makeSignal(visitCount: 3, category: .bar, hours: [22, 23])
        let cats = MyListsEngine.categories(for: signal)
        XCTAssertTrue(cats.contains(.lateNight))
        XCTAssertTrue(cats.contains(.nightlife))
    }

    // MARK: - Helpers

    private func makeSignal(
        visitCount: Int,
        category: PlaceCategory,
        hours: [Int],
        name: String = "Test Place",
        lat: Double? = nil,
        lng: Double? = nil,
        isFavorite: Bool = false
    ) -> MyListPlaceSignal {
        MyListPlaceSignal(
            poiId: "poi_1",
            yelpId: nil,
            placeId: "p_test123",
            name: name,
            category: category,
            latitude: lat ?? center.latitude + 0.001,
            longitude: lng ?? center.longitude + 0.001,
            visitCount: visitCount,
            avgDurationMinutes: 45,
            typicalHours: hours,
            lastVisit: Date(),
            favoriteRating: isFavorite ? 5 : nil,
            isExplicitFavorite: isFavorite
        )
    }
}
