import SwiftUI
import UIKit

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
