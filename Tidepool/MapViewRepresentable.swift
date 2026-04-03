import SwiftUI
import MapKit
import UIKit

struct HeatCircleOverlay {
    let coordinate: CLLocationCoordinate2D
    let radiusMeters: CLLocationDistance
    let intensity: CGFloat // 0...1
}

struct HeatBlobGroup: Equatable {
    let points: [CLLocationCoordinate2D]
    let baseIntensity: CGFloat
    let perUserRadiusMeters: CLLocationDistance
    
    static func == (lhs: HeatBlobGroup, rhs: HeatBlobGroup) -> Bool {
        return lhs.points.count == rhs.points.count &&
               lhs.baseIntensity == rhs.baseIntensity &&
               lhs.perUserRadiusMeters == rhs.perUserRadiusMeters &&
               zip(lhs.points, rhs.points).allSatisfy { 
                   abs($0.latitude - $1.latitude) < 1e-10 && 
                   abs($0.longitude - $1.longitude) < 1e-10 
               }
    }
}

final class POIAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    init(coordinate: CLLocationCoordinate2D, title: String?, subtitle: String?) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        super.init()
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
    func darkened(_ amount: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: max(r - amount, 0), green: max(g - amount, 0), blue: max(b - amount, 0), alpha: a)
    }
}

// MKOverlay that holds multiple heat blob groups and covers their union rect
final class HeatBlobOverlay: NSObject, MKOverlay {
    let groups: [HeatBlobGroup]
    private let _coordinate: CLLocationCoordinate2D
    private let _boundingMapRect: MKMapRect

    init(groups: [HeatBlobGroup]) {
        self.groups = groups
        // Compute average center
        var lats: [Double] = []
        var lons: [Double] = []
        var unionRect = MKMapRect.null
        for g in groups {
            for p in g.points {
                lats.append(p.latitude); lons.append(p.longitude)
                let mp = MKMapPoint(p)
                let r = MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0)
                unionRect = unionRect.union(r)
            }
        }
        let avgLat = lats.reduce(0, +) / Double(max(lats.count, 1))
        let avgLon = lons.reduce(0, +) / Double(max(lons.count, 1))
        _coordinate = CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
        // Pad rect generously to account for per-user radii and zoom
        _boundingMapRect = unionRect.insetBy(dx: -2000, dy: -2000)
    }

    var coordinate: CLLocationCoordinate2D { _coordinate }
    var boundingMapRect: MKMapRect { _boundingMapRect }
}

final class HeatBlobRenderer: MKOverlayRenderer {
    private let innerColor = UIColor(hex: "#9CE3A3") ?? .systemGreen
    private let outerColor = UIColor(hex: "#A6E4F8") ?? .systemTeal
    private let highContrast: Bool

    init(overlay: MKOverlay, highContrast: Bool) {
        self.highContrast = highContrast
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? HeatBlobOverlay else { return }

        // Detect appearance (light/dark) to tune alpha for visibility
        let isLightMode: Bool = UIScreen.main.traitCollection.userInterfaceStyle == .light

        for group in overlay.groups {
            guard !group.points.isEmpty else { continue }

            // Convert points to screen space
            let screenPoints: [CGPoint] = group.points.map { point(for: MKMapPoint($0)) }
            guard screenPoints.count >= 3 else { continue }

            // Compute centroid (for gradient center)
            let centroid: CGPoint = {
                var sx: CGFloat = 0, sy: CGFloat = 0
                for pt in screenPoints { sx += pt.x; sy += pt.y }
                let c = CGFloat(screenPoints.count)
                return CGPoint(x: sx / c, y: sy / c)
            }()

            // Approximate per-user radius in pixels using local latitude
            let ppm = MKMapPointsPerMeterAtLatitude(group.points.first!.latitude)
            let radiusMapPoints = group.perUserRadiusMeters * ppm
            let centerMapPoint = MKMapPoint(group.points.first!)
            let edgeMapPoint = MKMapPoint(x: centerMapPoint.x + radiusMapPoints, y: centerMapPoint.y)
            let centerPt = point(for: centerMapPoint)
            let edgePt = point(for: edgeMapPoint)
            let radiusPx = hypot(edgePt.x - centerPt.x, edgePt.y - centerPt.y)
            guard radiusPx > 1 else { continue }

            // Build convex hull of points in screen space (monotone chain)
            let hull = convexHull(points: screenPoints)
            guard hull.count >= 3 else { continue }

            // Create path from hull
            let hullPath = CGMutablePath()
            hullPath.move(to: hull[0])
            for i in 1..<hull.count { hullPath.addLine(to: hull[i]) }
            hullPath.closeSubpath()

            context.saveGState()

            // Clip to stroked hull (buffered by radiusPx) to approximate union of disks
            context.addPath(hullPath)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setLineWidth(radiusPx * 2)
            context.replacePathWithStrokedPath()
            context.clip()

            // Soft radial gradient; higher alpha in high-contrast for visibility
            let alphaBoost: CGFloat = isLightMode ? 0.12 : 0.0
            let contrastBoost: CGFloat = highContrast ? 0.22 : 0.0
            let innerAlpha: CGFloat = 0.24 + 0.45 * group.baseIntensity + alphaBoost + contrastBoost
            let midAlpha: CGFloat = 0.12 + 0.22 * group.baseIntensity + alphaBoost / 2 + contrastBoost / 2
            let outerAlpha: CGFloat = (isLightMode ? 0.10 : 0.05) + (highContrast ? 0.05 : 0.0)

            let maxDist: CGFloat = hull.map { hypot($0.x - centroid.x, $0.y - centroid.y) }.max() ?? radiusPx
            let endRadius = maxDist + radiusPx

            let colors = [
                innerColor.withAlphaComponent(min(1.0, innerAlpha)).cgColor,
                innerColor.withAlphaComponent(min(1.0, midAlpha)).cgColor,
                outerColor.withAlphaComponent(min(1.0, outerAlpha)).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.55, 1.0]
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: centroid, startRadius: 0,
                    endCenter: centroid, endRadius: endRadius,
                    options: [.drawsAfterEndLocation]
                )
            }

            context.restoreGState()
        }
    }

    private func convexHull(points: [CGPoint]) -> [CGPoint] {
        if points.count <= 1 { return points }
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(o: lower[lower.count-2], a: lower[lower.count-1], b: p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(o: upper[upper.count-2], a: upper[upper.count-1], b: p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }

    private func cross(o: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
}

final class HeatCircleRenderer: MKOverlayRenderer {
    private let circle: MKCircle
    private let intensity: CGFloat
    private let innerColor = UIColor(hex: "#9CE3A3") ?? .systemGreen
    private let outerColor = UIColor(hex: "#A6E4F8") ?? .systemTeal
    private let highContrast: Bool

    init(circle: MKCircle, intensity: CGFloat, highContrast: Bool) {
        self.circle = circle
        self.intensity = max(0, min(intensity, 1))
        self.highContrast = highContrast
        super.init(overlay: circle)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let centerMapPoint = MKMapPoint(circle.coordinate)
        let centerPt = point(for: centerMapPoint)
        let pointsPerMeter = MKMapPointsPerMeterAtLatitude(circle.coordinate.latitude)
        let radiusMapPoints = circle.radius * pointsPerMeter
        let edgeMapPoint = MKMapPoint(x: centerMapPoint.x + radiusMapPoints, y: centerMapPoint.y)
        let edgePt = point(for: edgeMapPoint)
        let radiusPx = hypot(edgePt.x - centerPt.x, edgePt.y - centerPt.y)
        guard radiusPx > 1 else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)

        let circlePath = CGMutablePath()
        circlePath.addEllipse(in: CGRect(x: centerPt.x - radiusPx, y: centerPt.y - radiusPx, width: radiusPx * 2, height: radiusPx * 2))
        context.addPath(circlePath)
        context.clip()

        // Increase alpha in high-contrast/light mode for better visibility
        let isLightMode = UIScreen.main.traitCollection.userInterfaceStyle == .light
        let alphaBoost: CGFloat = (isLightMode ? 0.12 : 0.0) + (highContrast ? 0.22 : 0.0)
        let innerAlpha: CGFloat = 0.28 + 0.42 * intensity + alphaBoost
        let midAlpha: CGFloat = 0.12 + 0.22 * intensity + alphaBoost / 2
        let outerAlpha: CGFloat = (isLightMode ? 0.10 : 0.05) + (highContrast ? 0.05 : 0.0)

        let colors = [
            innerColor.withAlphaComponent(min(1.0, innerAlpha)).cgColor,
            innerColor.withAlphaComponent(min(1.0, midAlpha)).cgColor,
            outerColor.withAlphaComponent(min(1.0, outerAlpha)).cgColor
        ] as CFArray
        let locations: [CGFloat] = [0.0, 0.55, 1.0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            context.drawRadialGradient(
                gradient,
                startCenter: centerPt, startRadius: 0,
                endCenter: centerPt, endRadius: radiusPx,
                options: [.drawsAfterEndLocation]
            )
        }

        context.restoreGState()
    }
}

struct MapViewRepresentable: UIViewRepresentable {
    let presenceOverlays: [PresenceCircleOverlay]
    let heatOverlays: [HeatCircleOverlay]
    let heatBlobGroups: [HeatBlobGroup]
    let highContrast: Bool
    let poiAnnotations: [POIAnnotation]
    let isDetailShowing: Bool
    @Binding var navigateToCoordinate: CLLocationCoordinate2D?
    let onAnnotationTap: ((POIAnnotation, CGPoint) -> Void)?
    let onCenterChanged: ((CLLocationCoordinate2D) -> Void)?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.isZoomEnabled = true
        mapView.showsCompass = false
        if #available(iOS 16.0, *) {
            let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            mapView.preferredConfiguration = cfg
        }
        // Show native Apple POIs with their original icons
        if #available(iOS 13.0, *) {
            let categories: [MKPointOfInterestCategory] = [.cafe, .restaurant, .nightlife, .park, .store, .museum, .hospital, .school, .library, .gasStation, .pharmacy, .bank, .hotel, .theater, .fitnessCenter]
            mapView.pointOfInterestFilter = MKPointOfInterestFilter(including: categories)
        }
        // Enable tap-to-select on native POI features (iOS 16+)
        if #available(iOS 16.0, *) {
            mapView.selectableMapFeatures = [.pointsOfInterest]
        }

        return mapView
    }

    /// Repositions Apple logo to bottom-center and hides the Legal link.
    private static var attributionAdjusted = false
    static func adjustAttributionViews(in mapView: MKMapView) {
        guard !attributionAdjusted else { return }
        guard mapView.bounds.width > 0 else { return }

        // Recursively collect all subviews in the hierarchy
        func allDescendants(of view: UIView) -> [UIView] {
            var result: [UIView] = []
            for sub in view.subviews {
                result.append(sub)
                result += allDescendants(of: sub)
            }
            return result
        }

        let allViews = allDescendants(of: mapView)
        var foundLogo = false
        var foundLegal = false

        for view in allViews {
            let typeName = String(describing: type(of: view))

            // The Apple Maps logo: internal class typically contains "Logo"
            if typeName.lowercased().contains("logo") {
                foundLogo = true
                view.translatesAutoresizingMaskIntoConstraints = false
                // Deactivate existing positioning constraints
                for constraint in view.superview?.constraints ?? [] {
                    if constraint.firstItem === view || constraint.secondItem === view {
                        constraint.isActive = false
                    }
                }
                NSLayoutConstraint.activate([
                    view.centerXAnchor.constraint(equalTo: mapView.centerXAnchor),
                    view.bottomAnchor.constraint(equalTo: mapView.bottomAnchor, constant: -4)
                ])
                continue
            }

            // The Legal/Attribution link: class typically contains "Attribution" or "Legal"
            if typeName.lowercased().contains("attribution") || typeName.lowercased().contains("legal") {
                foundLegal = true
                view.isHidden = true
                continue
            }
        }

        if foundLogo || foundLegal {
            attributionAdjusted = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        // Reposition Apple logo to bottom-center, hide Legal link
        Self.adjustAttributionViews(in: mapView)

        // Keep coordinator in sync with latest closures and state
        context.coordinator.highContrast = highContrast
        context.coordinator.onAnnotationTap = onAnnotationTap
        context.coordinator.onCenterChanged = onCenterChanged

        // Deselect POI when the detail modal is dismissed
        if !isDetailShowing && context.coordinator.wasDetailShowing {
            for annotation in mapView.selectedAnnotations {
                mapView.deselectAnnotation(annotation, animated: true)
            }
        }
        context.coordinator.wasDetailShowing = isDetailShowing

        // Animate to a target coordinate if requested
        if let target = navigateToCoordinate {
            let region = MKCoordinateRegion(center: target, latitudinalMeters: 800, longitudinalMeters: 800)
            mapView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                self.navigateToCoordinate = nil
            }
        }

        mapView.removeOverlays(mapView.overlays)

        if !heatBlobGroups.isEmpty {
            let blob = HeatBlobOverlay(groups: heatBlobGroups)
            mapView.addOverlay(blob)
        }

        for heat in heatOverlays {
            let circle = MKCircle(center: heat.coordinate, radius: heat.radiusMeters)
            circle.title = "heat:\(min(max(heat.intensity, 0), 1))"
            mapView.addOverlay(circle)
        }

        for overlay in presenceOverlays {
            let circle = MKCircle(center: overlay.coordinate, radius: overlay.radiusMeters)
            circle.title = "presence"
            mapView.addOverlay(circle)
        }

        // Sync custom POI annotations (e.g. search result pins)
        let existing = mapView.annotations.compactMap { $0 as? POIAnnotation }
        let existingSet = Set(existing.map { ObjectIdentifier($0) })
        let newSet = Set(poiAnnotations.map { ObjectIdentifier($0) })

        if existingSet != newSet {
            mapView.removeAnnotations(existing)
            if !poiAnnotations.isEmpty {
                mapView.addAnnotations(poiAnnotations)
                // Auto-select the pin after a brief delay so the drop animation plays first,
                // then the selection bounce kicks in
                let annotations = poiAnnotations
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    for annotation in annotations {
                        mapView.selectAnnotation(annotation, animated: true)
                    }
                }
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var highContrast: Bool = true
        var wasDetailShowing: Bool = false
        var onAnnotationTap: ((POIAnnotation, CGPoint) -> Void)?
        var onCenterChanged: ((CLLocationCoordinate2D) -> Void)?

        func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
            // Best time to adjust attribution — all internal subviews are in place
            MapViewRepresentable.adjustAttributionViews(in: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onCenterChanged?(mapView.centerCoordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is HeatBlobOverlay {
                return HeatBlobRenderer(overlay: overlay, highContrast: highContrast)
            }
            if let circle = overlay as? MKCircle {
                if let title = circle.title, title.hasPrefix("heat:") {
                    let parts = title.split(separator: ":")
                    let intensity = parts.count == 2 ? CGFloat(Double(parts[1]) ?? 0.0) : 0.0
                    return HeatCircleRenderer(circle: circle, intensity: intensity, highContrast: highContrast)
                } else {
                    let renderer = MKCircleRenderer(circle: circle)
                    renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.18)
                    renderer.strokeColor = UIColor.clear
                    renderer.lineWidth = 0
                    return renderer
                }
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // Let MapKit handle native POI annotations with their default appearance
            // Only customize our custom POI annotations if any exist
            if let poi = annotation as? POIAnnotation {
                let identifier = "POIMarker"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                if view == nil {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    view?.canShowCallout = false
                    view?.animatesWhenAdded = true
                    view?.displayPriority = .required
                } else {
                    view?.annotation = annotation
                }

                // Tidepool-branded search result pin
                let (icon, _) = Self.categoryAppearance(for: poi.subtitle)
                view?.glyphImage = UIImage(systemName: icon)
                view?.markerTintColor = UIColor(hex: "#7BC9FF") ?? .systemTeal
                view?.titleVisibility = .visible
                view?.subtitleVisibility = .hidden
                view?.selectedGlyphImage = UIImage(systemName: icon)

                return view
            }

            // Return nil to let MapKit use default native POI appearance
            return nil
        }

        private static func categoryAppearance(for category: String?) -> (icon: String, color: UIColor) {
            guard let cat = category?.lowercased() else {
                return ("mappin.circle.fill", UIColor(hex: "#7BC9FF") ?? .systemTeal)
            }

            switch cat {
            case let c where c.contains("restaurant") || c.contains("food"):
                return ("fork.knife", .systemOrange)
            case let c where c.contains("cafe") || c.contains("coffee"):
                return ("cup.and.saucer.fill", .brown)
            case let c where c.contains("bar") || c.contains("nightlife"):
                return ("wineglass.fill", .systemPurple)
            case let c where c.contains("park"):
                return ("tree.fill", .systemGreen)
            case let c where c.contains("store") || c.contains("shop") || c.contains("retail"):
                return ("bag.fill", .systemBlue)
            case let c where c.contains("museum"):
                return ("building.columns.fill", .systemBrown)
            case let c where c.contains("gym") || c.contains("fitness"):
                return ("dumbbell.fill", .systemRed)
            case let c where c.contains("hospital") || c.contains("medical"):
                return ("cross.fill", .systemRed)
            case let c where c.contains("school") || c.contains("university"):
                return ("graduationcap.fill", .systemIndigo)
            case let c where c.contains("library"):
                return ("book.fill", .systemBrown)
            case let c where c.contains("gas"):
                return ("fuelpump.fill", .systemOrange)
            case let c where c.contains("bank") || c.contains("pharmacy"):
                return ("building.2.fill", .systemTeal)
            case let c where c.contains("hotel"):
                return ("bed.double.fill", .systemBlue)
            default:
                return ("mappin.circle.fill", UIColor(hex: "#7BC9FF") ?? .systemTeal)
            }
        }
        
        // iOS 16+ delegate for selectable map features (native POIs)
        @available(iOS 16.0, *)
        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            if annotation is MKUserLocation { return }

            // If this is a programmatic selection (search result pin while detail is already showing),
            // just let the selection animation play — don't re-trigger the detail sheet
            if annotation is POIAnnotation && wasDetailShowing {
                return
            }

            // Smoothly center the map on the tapped POI
            let targetCoord = annotation.coordinate
            UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseInOut) {
                mapView.setCenter(targetCoord, animated: false)
            }

            // Convert annotation coordinate to screen point for the sheet origin
            let mapPoint = mapView.convert(annotation.coordinate, toPointTo: mapView)
            let screenPoint = mapView.convert(mapPoint, to: nil)

            if let feature = annotation as? MKMapFeatureAnnotation {
                let categoryString = feature.pointOfInterestCategory?.rawValue
                let poiAnnotation = POIAnnotation(
                    coordinate: feature.coordinate,
                    title: feature.title ?? "Unknown Place",
                    subtitle: categoryString
                )
                onAnnotationTap?(poiAnnotation, screenPoint)
            } else if let poiAnnotation = annotation as? POIAnnotation {
                onAnnotationTap?(poiAnnotation, screenPoint)
            } else {
                let poiAnnotation = POIAnnotation(
                    coordinate: annotation.coordinate,
                    title: annotation.title ?? "Unknown Place",
                    subtitle: nil
                )
                onAnnotationTap?(poiAnnotation, screenPoint)
            }

            // POI stays selected while detail modal is open — deselection handled in updateUIView
        }

        // Fallback for pre-iOS 16 (annotation view-based selection)
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            if annotation is MKUserLocation { return }

            // On iOS 16+, the annotation-based didSelect handles features
            if #available(iOS 16.0, *) { return }

            // Smoothly center the map on the tapped POI
            UIView.animate(withDuration: 0.4, delay: 0, options: .curveEaseInOut) {
                mapView.setCenter(annotation.coordinate, animated: false)
            }

            let tapPoint = mapView.convert(view.center, to: nil)
            let poiAnnotation = POIAnnotation(
                coordinate: annotation.coordinate,
                title: annotation.title ?? "Unknown Place",
                subtitle: nil
            )
            onAnnotationTap?(poiAnnotation, tapPoint)
            // POI stays selected while detail modal is open — deselection handled in updateUIView
        }
    }
} 