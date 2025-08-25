import Foundation
import CoreLocation

struct TileId: Hashable, CustomStringConvertible {
    let x: Int
    let y: Int
    let metersPerTile: Int
    var description: String { "grid_\(metersPerTile)_m_\(x)_\(y)" }
}

enum SimpleGridTiler {
    static func tileId(for coordinate: CLLocationCoordinate2D, metersPerTile: Int = 150) -> TileId {
        let latMeters = 111_000.0
        let lonMeters = latMeters * cos(coordinate.latitude * .pi / 180)
        let dLat = Double(metersPerTile) / latMeters
        let dLon = Double(metersPerTile) / lonMeters
        let x = Int(floor((coordinate.longitude + 180.0) / dLon))
        let y = Int(floor((coordinate.latitude + 90.0) / dLat))
        return TileId(x: x, y: y, metersPerTile: metersPerTile)
    }
} 