import Foundation
import CoreLocation

protocol Tiler {
    func tileIdString(for coordinate: CLLocationCoordinate2D) -> String
}

struct GridTiler: Tiler {
    let metersPerTile: Int
    init(metersPerTile: Int = 150) { self.metersPerTile = metersPerTile }
    func tileIdString(for coordinate: CLLocationCoordinate2D) -> String {
        let id = SimpleGridTiler.tileId(for: coordinate, metersPerTile: metersPerTile)
        return id.description
    }
}

#if canImport(H3kit)
import H3kit

struct H3Tiler: Tiler {
    let resolution: Int32
    init(resolution: Int32 = 9) { self.resolution = resolution }
    func tileIdString(for coordinate: CLLocationCoordinate2D) -> String {
        let index = coordinate.h3CellIndex(resolution: resolution)
        return String(index, radix: 16, uppercase: true)
    }
}
#endif

enum Tiling {
    #if canImport(H3kit)
    static var current: Tiler = H3Tiler(resolution: 9)
    #else
    static var current: Tiler = GridTiler(metersPerTile: 150)
    #endif
} 