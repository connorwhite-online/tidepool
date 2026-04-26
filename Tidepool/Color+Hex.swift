import SwiftUI
import UIKit

extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255.0
        let g = Double((v >> 8) & 0xFF) / 255.0
        let b = Double(v & 0xFF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}

/// Renders either a custom asset-catalog symbol or an SF Symbol.
/// Custom symbols get scaled up ~1.3x to compensate for glyph bounding boxes
/// that fill only ~80% of the cap-height region in the SVG templates.
struct AdaptiveSymbol: View {
    let name: String
    var body: some View {
        if UIImage(named: name) != nil {
            Image(name).scaleEffect(2.0)
        } else {
            Image(systemName: name)
        }
    }
}
