import SwiftUI
import MapKit

struct HomePickerMapRepresentable: UIViewRepresentable {
    @Binding var centerCoordinate: CLLocationCoordinate2D
    let initialRegion: MKCoordinateRegion

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.setRegion(initialRegion, animated: false)
        mapView.showsUserLocation = true
        mapView.isZoomEnabled = true
        mapView.isRotateEnabled = true
        mapView.isPitchEnabled = true
        return mapView
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // No-op; centerCoordinate is driven by delegate callbacks
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        let parent: HomePickerMapRepresentable
        init(parent: HomePickerMapRepresentable) {
            self.parent = parent
        }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            parent.centerCoordinate = mapView.region.center
        }
    }
} 