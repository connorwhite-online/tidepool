import XCTest
@testable import TidepoolShared

final class InterestVectorTests: XCTestCase {

    func testVocabularyDimensions() {
        XCTAssertEqual(InterestVocabulary.dimensions, InterestVocabulary.tags.count)
        XCTAssertEqual(InterestVocabulary.dimensions, 95)
    }

    func testVocabularyNoDuplicates() {
        let tags = InterestVocabulary.tags
        let unique = Set(tags)
        XCTAssertEqual(tags.count, unique.count, "Vocabulary contains duplicate tags")
    }

    func testTagLookup() {
        XCTAssertNotNil(InterestVocabulary.index(of: "rock"))
        XCTAssertNotNil(InterestVocabulary.index(of: "dining"))
        XCTAssertNil(InterestVocabulary.index(of: "nonexistent_tag"))
    }

    func testEmptyVector() {
        let v = InterestVector()
        XCTAssertEqual(v.values.count, InterestVocabulary.dimensions)
        XCTAssertTrue(v.values.allSatisfy { $0 == 0 })
    }

    func testCosineSimilarityIdentical() {
        let v = InterestVector(tagWeights: ["rock": 5, "indie": 3, "music": 2])
        let sim = v.cosineSimilarity(to: v)
        XCTAssertEqual(sim, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        let v1 = InterestVector(tagWeights: ["rock": 5])
        let v2 = InterestVector(tagWeights: ["dining": 5])
        let sim = v1.cosineSimilarity(to: v2)
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityZeroVector() {
        let v1 = InterestVector()
        let v2 = InterestVector(tagWeights: ["rock": 5])
        XCTAssertEqual(v1.cosineSimilarity(to: v2), 0.0)
    }

    func testTopTags() {
        let v = InterestVector(tagWeights: ["rock": 10, "indie": 5, "pop": 3, "jazz": 1])
        let top = v.topTags(limit: 3)
        XCTAssertEqual(top.count, 3)
        XCTAssertTrue(top[0].weight >= top[1].weight)
    }

    func testSubscript() {
        var v = InterestVector()
        v["rock"] = 0.5
        XCTAssertEqual(v["rock"], 0.5)
        XCTAssertEqual(v["nonexistent"], 0)
    }

    func testTileIDConsistency() {
        let coord = Coordinate(latitude: 34.0522, longitude: -118.2437) // LA
        let tile = GridTiler.tileID(for: coord)
        let tile2 = GridTiler.tileID(for: coord)
        XCTAssertEqual(tile, tile2)
        XCTAssertTrue(tile.description.hasPrefix("grid_150_m_"))
    }

    func testTilesInBounds() {
        let sw = Coordinate(latitude: 34.05, longitude: -118.25)
        let ne = Coordinate(latitude: 34.06, longitude: -118.24)
        let tiles = GridTiler.tilesInBounds(sw: sw, ne: ne)
        XCTAssertTrue(tiles.count > 0)
    }

    func testPlaceCategoryInterestTags() {
        let tags = PlaceCategory.restaurant.interestTags
        XCTAssertTrue(tags.contains("dining"))
        XCTAssertTrue(tags.contains("restaurant"))
    }
}
