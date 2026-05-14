import SwiftUI
import UIKit

// MARK: - Spring Physics Configuration

struct SpringPhysics {
    let damping: Double
    let stiffness: Double
    let mass: Double

    /// Standard Spring: Damping 0.75, Stiffness 300, Mass 1.0 (for most UI transitions)
    static let standard = SpringPhysics(damping: 0.75, stiffness: 300, mass: 1.0)

    /// Snappy Spring: Damping 0.8, Stiffness 400, Mass 0.8 (for button interactions, favorites)
    static let snappy = SpringPhysics(damping: 0.8, stiffness: 400, mass: 0.8)

    /// Gentle Spring: Damping 0.85, Stiffness 200, Mass 1.2 (for large content transitions, modals)
    static let gentle = SpringPhysics(damping: 0.85, stiffness: 200, mass: 1.2)

    /// Map Spring: Damping 0.9, Stiffness 250, Mass 1.0 (for map pan/zoom with momentum)
    static let map = SpringPhysics(damping: 0.9, stiffness: 250, mass: 1.0)

    var swiftUISpring: Animation {
        .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping)
    }

    var uiKitSpring: UISpringTimingParameters {
        UISpringTimingParameters(mass: CGFloat(mass), stiffness: CGFloat(stiffness), damping: CGFloat(damping), initialVelocity: .zero)
    }
}

// MARK: - Satisfying Spring (favorites micro-interaction)

extension View {
    func satisfyingSpring(isActive: Bool) -> some View {
        self.modifier(SatisfyingSpringModifier(isActive: isActive))
    }
}

struct SatisfyingSpringModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive ? 1.2 : 1.0)
            .animation(SpringPhysics.snappy.swiftUISpring, value: isActive)
    }
}

// MARK: - Haptic Feedback

class HapticFeedbackManager {
    static let shared = HapticFeedbackManager()

    private init() {}

    func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
