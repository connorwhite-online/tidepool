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

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        mapView.isZoomEnabled = true
        if #available(iOS 16.0, *) {
            let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            mapView.preferredConfiguration = cfg
        }
        // Hide built-in Apple POIs; we'll add filtered ones manually
        if #available(iOS 13.0, *) {
            mapView.pointOfInterestFilter = .excludingAll
        }
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
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

        // Update POI annotations
        let existing = mapView.annotations.compactMap { $0 as? POIAnnotation }
        mapView.removeAnnotations(existing)
        mapView.addAnnotations(poiAnnotations)

        // Do not override camera/region; keep following the user location
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(getHighContrast: { self.highContrast })
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let getHighContrast: () -> Bool
        init(getHighContrast: @escaping () -> Bool) {
            self.getHighContrast = getHighContrast
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is HeatBlobOverlay {
                return HeatBlobRenderer(overlay: overlay, highContrast: getHighContrast())
            }
            if let circle = overlay as? MKCircle {
                if let title = circle.title, title.hasPrefix("heat:") {
                    let parts = title.split(separator: ":")
                    let intensity = parts.count == 2 ? CGFloat(Double(parts[1]) ?? 0.0) : 0.0
                    return HeatCircleRenderer(circle: circle, intensity: intensity, highContrast: getHighContrast())
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
            guard annotation is POIAnnotation else { return nil }
            let identifier = "POIMarker"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
                view?.glyphImage = UIImage(systemName: "mappin.circle.fill")
                view?.markerTintColor = UIColor(hex: "#7BC9FF") ?? .systemTeal
            } else {
                view?.annotation = annotation
            }
            return view
        }
    }
} 