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

// MARK: - Animation Durations

struct AnimationDuration {
    /// Micro-interactions: 150-300ms (favorites, button states, small UI changes)
    static let micro: TimeInterval = 0.25
    
    /// Content Transitions: 400-600ms (sheet presentations, tab changes, search expansion)
    static let content: TimeInterval = 0.5
    
    /// Large State Changes: 600-800ms (modal presentations, onboarding flow)
    static let large: TimeInterval = 0.7
    
    /// Map Animations: Variable duration based on distance/zoom (min 200ms, max 1200ms)
    static let mapMin: TimeInterval = 0.2
    static let mapMax: TimeInterval = 1.2
}

// MARK: - Shared Element Transition System

protocol SharedElementTransition {
    var sharedElementID: String { get }
    var sourceFrame: CGRect { get }
    var destinationFrame: CGRect { get }
}

class SharedElementCoordinator: ObservableObject {
    @Published private var activeTransitions: [String: SharedElementTransition] = [:]
    
    func registerTransition(_ transition: SharedElementTransition) {
        activeTransitions[transition.sharedElementID] = transition
    }
    
    func completeTransition(for id: String) {
        activeTransitions.removeValue(forKey: id)
    }
    
    func getTransition(for id: String) -> SharedElementTransition? {
        return activeTransitions[id]
    }
}

// MARK: - Fluid Interface Modifiers

extension View {
    /// Apply standard spring physics to any view transition
    func fluidTransition(physics: SpringPhysics = .standard) -> some View {
        self.animation(physics.swiftUISpring, value: UUID())
    }
    
    /// Origin-based transition that emerges from a specific interaction point
    func originBasedTransition(from origin: CGPoint, physics: SpringPhysics = .standard) -> some View {
        self.modifier(OriginBasedTransitionModifier(origin: origin, physics: physics))
    }
    
    /// Shared element transition for spatial consistency
    func sharedElement(id: String, coordinator: SharedElementCoordinator) -> some View {
        self.modifier(SharedElementModifier(id: id, coordinator: coordinator))
    }
    
    /// Satisfying spring animation for favorites and micro-interactions
    func satisfyingSpring(isActive: Bool) -> some View {
        self.modifier(SatisfyingSpringModifier(isActive: isActive))
    }
    
    /// Staggered animation for lists and search results
    func staggeredAnimation(delay: Double) -> some View {
        self.modifier(StaggeredAnimationModifier(delay: delay))
    }
    
    /// Reduced motion alternative that respects accessibility preferences
    func reducedMotionAlternative<Alternative: View>(@ViewBuilder alternative: @escaping () -> Alternative) -> some View {
        self.modifier(ReducedMotionModifier(alternative: alternative))
    }
}

// MARK: - Animation Modifiers

struct OriginBasedTransitionModifier: ViewModifier {
    let origin: CGPoint
    let physics: SpringPhysics
    @State private var isPresented = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPresented ? 1.0 : 0.1)
            .offset(x: isPresented ? 0 : origin.x, y: isPresented ? 0 : origin.y)
            .opacity(isPresented ? 1.0 : 0.0)
            .animation(physics.swiftUISpring, value: isPresented)
            .onAppear {
                isPresented = true
            }
    }
}

struct SharedElementModifier: ViewModifier {
    let id: String
    let coordinator: SharedElementCoordinator
    @State private var frame: CGRect = .zero
    
    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            frame = geometry.frame(in: .global)
                        }
                        .onChange(of: geometry.frame(in: .global)) { _, newFrame in
                            frame = newFrame
                        }
                }
            )
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

struct StaggeredAnimationModifier: ViewModifier {
    let delay: Double
    @State private var isVisible = false
    
    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1.0 : 0.0)
            .offset(y: isVisible ? 0 : 20)
            .animation(SpringPhysics.standard.swiftUISpring.delay(delay), value: isVisible)
            .onAppear {
                isVisible = true
            }
    }
}

struct ReducedMotionModifier<Alternative: View>: ViewModifier {
    let alternative: () -> Alternative
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    init(alternative: @escaping () -> Alternative) {
        self.alternative = alternative
    }
    
    func body(content: Content) -> some View {
        if reduceMotion {
            alternative()
        } else {
            content
        }
    }
}

// MARK: - Fluid Sheet Presentation

struct FluidSheetPresentation<Content: View>: View {
    @Binding var isPresented: Bool
    let content: Content
    let physics: SpringPhysics
    
    init(isPresented: Binding<Bool>, physics: SpringPhysics = .gentle, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.physics = physics
        self.content = content()
    }
    
    var body: some View {
        ZStack {
            if isPresented {
                // Background overlay
                Color.black
                    .opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }
                    .transition(.opacity)
                
                // Sheet content
                VStack {
                    Spacer()
                    content
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(physics.swiftUISpring, value: isPresented)
    }
}

// MARK: - Progressive Disclosure Loading

struct ProgressiveLoadingView<Content: View>: View {
    let content: Content
    let isLoading: Bool
    let skeletonHeight: CGFloat
    
    init(isLoading: Bool, skeletonHeight: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.isLoading = isLoading
        self.skeletonHeight = skeletonHeight
        self.content = content()
    }
    
    var body: some View {
        if isLoading {
            SkeletonView(height: skeletonHeight)
        } else {
            content
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                .animation(SpringPhysics.standard.swiftUISpring, value: isLoading)
        }
    }
}

struct SkeletonView: View {
    let height: CGFloat
    @State private var isAnimating = false
    
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(height: height)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.3), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .offset(x: isAnimating ? 200 : -200)
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isAnimating)
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// MARK: - Haptic Feedback System

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

// MARK: - Spring-based Pull-to-Refresh

struct SpringPullToRefresh<Content: View>: View {
    @Binding var isRefreshing: Bool
    let onRefresh: () async -> Void
    let content: Content
    
    init(isRefreshing: Binding<Bool>, onRefresh: @escaping () async -> Void, @ViewBuilder content: () -> Content) {
        self._isRefreshing = isRefreshing
        self.onRefresh = onRefresh
        self.content = content()
    }
    
    var body: some View {
        ScrollView {
            content
                .refreshable {
                    await onRefresh()
                }
        }
        .animation(SpringPhysics.standard.swiftUISpring, value: isRefreshing)
    }
}

// MARK: - Dimensional Coherence Helpers

struct DimensionalTransition: ViewModifier {
    let isPresented: Bool
    let direction: TransitionDirection
    
    enum TransitionDirection {
        case fromTop, fromBottom, fromLeading, fromTrailing, fromCenter
    }
    
    func body(content: Content) -> some View {
        content
            .offset(offsetForDirection)
            .opacity(isPresented ? 1.0 : 0.0)
            .scaleEffect(isPresented ? 1.0 : 0.95)
            .animation(SpringPhysics.standard.swiftUISpring, value: isPresented)
    }
    
    private var offsetForDirection: CGSize {
        guard !isPresented else { return .zero }
        
        switch direction {
        case .fromTop: return CGSize(width: 0, height: -50)
        case .fromBottom: return CGSize(width: 0, height: 50)
        case .fromLeading: return CGSize(width: -50, height: 0)
        case .fromTrailing: return CGSize(width: 50, height: 0)
        case .fromCenter: return .zero
        }
    }
}

extension View {
    func dimensionalTransition(isPresented: Bool, from direction: DimensionalTransition.TransitionDirection) -> some View {
        self.modifier(DimensionalTransition(isPresented: isPresented, direction: direction))
    }
}

// MARK: - Performance Monitoring

class AnimationPerformanceMonitor: ObservableObject {
    @Published var frameRate: Double = 60.0
    @Published var isOptimal: Bool = true
    
    private var displayLink: CADisplayLink?
    private var frameCount = 0
    private var lastTimestamp: CFTimeInterval = 0
    
    func startMonitoring() {
        displayLink = CADisplayLink(target: self, selector: #selector(updateFrameRate))
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stopMonitoring() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updateFrameRate(_ displayLink: CADisplayLink) {
        if lastTimestamp == 0 {
            lastTimestamp = displayLink.timestamp
            return
        }
        
        frameCount += 1
        let elapsed = displayLink.timestamp - lastTimestamp
        
        if elapsed >= 1.0 {
            frameRate = Double(frameCount) / elapsed
            isOptimal = frameRate >= 55.0 // Consider 55+ fps as optimal
            frameCount = 0
            lastTimestamp = displayLink.timestamp
        }
    }
}

// MARK: - Device Performance Adaptation

struct DevicePerformanceAdapter {
    static func adaptedPhysics(base: SpringPhysics) -> SpringPhysics {
        let device = UIDevice.current
        
        // Adapt physics based on device performance characteristics
        if device.userInterfaceIdiom == .phone {
            // Slightly more gentle on phones for better battery life
            return SpringPhysics(
                damping: base.damping + 0.05,
                stiffness: base.stiffness * 0.9,
                mass: base.mass
            )
        }
        
        return base
    }
    
    static var shouldReduceAnimations: Bool {
        let device = UIDevice.current
        
        // Reduce animations on older devices
        if device.userInterfaceIdiom == .phone {
            // This is a simplified check - in practice you'd want to check specific device models
            return ProcessInfo.processInfo.physicalMemory < 3_000_000_000 // Less than 3GB RAM
        }
        
        return false
    }
}
