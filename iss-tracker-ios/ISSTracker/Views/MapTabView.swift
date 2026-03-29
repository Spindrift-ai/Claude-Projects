import SwiftUI
import MapKit

struct MapTabView: View {
    @EnvironmentObject var vm: ISSViewModel
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span:   MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 120)
    )
    @State private var trackingISS = true

    var body: some View {
        ZStack(alignment: .bottom) {
            ISSMapView(vm: vm, region: $region, trackingISS: $trackingISS)
                .ignoresSafeArea()

            // Info overlay
            VStack(spacing: 0) {
                statusBanner
                issInfoBar
            }
        }
        .onChange(of: vm.issPosition) { pos in
            guard trackingISS, let pos else { return }
            withAnimation(.easeInOut(duration: 2)) {
                region.center = CLLocationCoordinate2D(latitude: pos.latitude, longitude: pos.longitude)
            }
        }
        .navigationTitle("Live Tracking")
    }

    private var statusBanner: some View {
        HStack {
            Circle()
                .fill(vm.issPosition != nil ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(vm.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                trackingISS.toggle()
            } label: {
                Image(systemName: trackingISS ? "location.fill" : "location.slash")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var issInfoBar: some View {
        HStack(spacing: 0) {
            if let pos = vm.issPosition {
                infoCell(label: "Altitude", value: String(format: "%.0f km", pos.altitude))
                Divider().frame(height: 30)
                infoCell(label: "Velocity", value: String(format: "%.0f km/h", pos.velocity))
                Divider().frame(height: 30)
                infoCell(label: "Lat", value: String(format: "%.2f°", pos.latitude))
                Divider().frame(height: 30)
                infoCell(label: "Lon", value: String(format: "%.2f°", pos.longitude))
            } else {
                Text("Waiting for ISS data…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func infoCell(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - UIViewRepresentable MapKit Wrapper

struct ISSMapView: UIViewRepresentable {
    @ObservedObject var vm: ISSViewModel
    @Binding var region: MKCoordinateRegion
    @Binding var trackingISS: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate        = context.coordinator
        map.mapType         = .hybridFlyover
        map.showsScale      = true
        map.showsCompass    = true
        map.isZoomEnabled   = true
        map.isScrollEnabled = true
        map.setRegion(region, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        // Update ISS annotation
        let existing = map.annotations.compactMap { $0 as? ISSAnnotation }
        if let pos = vm.issPosition {
            let coord = CLLocationCoordinate2D(latitude: pos.latitude, longitude: pos.longitude)
            if let ann = existing.first {
                UIView.animate(withDuration: 2.0) {
                    ann.coordinate = coord
                }
            } else {
                let ann = ISSAnnotation(coordinate: coord)
                map.addAnnotation(ann)
            }
        }

        // Update user location marker
        if let loc = vm.userLocation {
            let existingUser = map.annotations.compactMap { $0 as? UserAnnotation }
            if existingUser.isEmpty {
                map.addAnnotation(UserAnnotation(coordinate: loc.coordinate))
            }
        }

        // Update pass ground track for the next pass
        let overlays = map.overlays.filter { $0 is MKPolyline }
        if !overlays.isEmpty { map.removeOverlays(overlays) }
        if let nextPass = vm.upcomingPasses.first,
           nextPass.start.timeIntervalSinceNow > 0,
           let tle = vm.issPosition {
            // Draw a simple great-circle path from current position to next pass start
            // (full ground track computed in a background task if needed)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is ISSAnnotation {
                let id = "ISS"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ??
                           MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image      = UIImage(systemName: "dot.radiowaves.right")?
                    .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
                    .resized(to: CGSize(width: 36, height: 36))
                view.canShowCallout = true
                return view
            }
            if annotation is UserAnnotation {
                let id = "User"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ??
                           MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image      = UIImage(systemName: "house.fill")?
                    .withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
                    .resized(to: CGSize(width: 28, height: 28))
                view.canShowCallout = true
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = .systemYellow.withAlphaComponent(0.7)
                r.lineWidth   = 2
                r.lineDashPattern = [8, 4]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Custom Annotations

class ISSAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?   = "ISS"
    var subtitle: String? = "International Space Station"
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

class UserAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var title: String?   = "Your Location"
    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

// MARK: - UIImage resize helper

private extension UIImage {
    func resized(to size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            self.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
