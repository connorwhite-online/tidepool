import Foundation

// MARK: - Tile ID

/// Identifies a grid tile in the Tidepool tiling system.
/// The same formula must be used on client and server for tile ID consistency.
public struct TileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let x: Int
    public let y: Int
    public let metersPerTile: Int

    public var description: String { "grid_\(metersPerTile)_m_\(x)_\(y)" }

    public init(x: Int, y: Int, metersPerTile: Int) {
        self.x = x
        self.y = y
        self.metersPerTile = metersPerTile
    }
}

// MARK: - Coordinate (platform-agnostic)

/// A simple lat/lng pair usable on both iOS and Linux (no CoreLocation dependency).
public struct Coordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - Grid Tiler

/// Computes tile IDs using a simple equirectangular grid.
/// Must produce identical results on client and server.
public enum GridTiler {
    public static let defaultMetersPerTile = 150

    public static func tileID(for coordinate: Coordinate, metersPerTile: Int = defaultMetersPerTile) -> TileID {
        let latMeters = 111_000.0
        let lonMeters = latMeters * cos(coordinate.latitude * .pi / 180)
        let dLat = Double(metersPerTile) / latMeters
        let dLon = Double(metersPerTile) / lonMeters
        let x = Int(floor((coordinate.longitude + 180.0) / dLon))
        let y = Int(floor((coordinate.latitude + 90.0) / dLat))
        return TileID(x: x, y: y, metersPerTile: metersPerTile)
    }

    /// Enumerate all tile IDs within a bounding box
    public static func tilesInBounds(
        sw: Coordinate,
        ne: Coordinate,
        metersPerTile: Int = defaultMetersPerTile
    ) -> [TileID] {
        let swTile = tileID(for: sw, metersPerTile: metersPerTile)
        let neTile = tileID(for: ne, metersPerTile: metersPerTile)

        var tiles: [TileID] = []
        for x in swTile.x...neTile.x {
            for y in swTile.y...neTile.y {
                tiles.append(TileID(x: x, y: y, metersPerTile: metersPerTile))
            }
        }
        return tiles
    }
}
