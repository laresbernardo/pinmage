import SwiftUI
import MapKit

struct InteractiveMapEditorView: View {
    let item: ImageItem
    @ObservedObject var manager: PinmageManager
    @Environment(\.dismiss) var dismiss
    
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var resolvedPlaceName: String = ""
    @State private var searchText: String = ""
    @State private var isSearching = false
    @State private var isReverseGeocoding = false
    @State private var mapCenterNeedUpdate = true
    @State private var thumbnail: NSImage? = nil
    @State private var showingPreviewPopover = false
    
    init(item: ImageItem, manager: PinmageManager) {
        self.item = item
        self.manager = manager
        
        let initialCoord: CLLocationCoordinate2D?
        if let lat = item.latitude ?? item.existingLatitude,
           let lon = item.longitude ?? item.existingLongitude {
            initialCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        } else {
            initialCoord = nil
        }
        
        _coordinate = State(initialValue: initialCoord)
        _resolvedPlaceName = State(initialValue: item.detectedPlace ?? item.geocodedPlace ?? "")
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pin Location on Map")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(item.fileName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Search Bar
                HStack(spacing: 8) {
                    TextField("Search city, address, or landmark...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 250)
                        .onSubmit {
                            performSearch()
                        }
                    
                    Button(action: performSearch) {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.2))
            
            Divider().background(Color.white.opacity(0.1))
            
            // Map Area
            ZStack(alignment: .topTrailing) {
                MapEditorViewRepresentable(
                    coordinate: $coordinate,
                    mapCenterNeedUpdate: $mapCenterNeedUpdate
                )
                
                // Instructions Overlay
                Text("Double-click map or drag pin to relocate")
                    .font(.caption2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white.opacity(0.9))
                    .cornerRadius(6)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider().background(Color.white.opacity(0.1))
            
            // Footer Info & Actions
            HStack(spacing: 16) {
                // Thumbnail preview for context
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 60, height: 60)
                    
                    if let thumb = thumbnail {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture {
                    showingPreviewPopover = true
                }
                .help("Click to enlarge")
                .popover(isPresented: $showingPreviewPopover, arrowEdge: .top) {
                    ImagePreviewPopover(fileURL: item.fileURL)
                }
                
                // Coordinates and resolved place description
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .foregroundColor(.cyan)
                            .font(.system(size: 12))
                        if let coord = coordinate {
                            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .contextMenu {
                                    Button("Copy Coordinates") {
                                        let text = String(format: "%.6f, %.6f", coord.latitude, coord.longitude)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(text, forType: .string)
                                    }
                                }
                        } else {
                            Text("No location set (Double-click map to place pin)")
                                .italic()
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse")
                            .foregroundColor(.emerald)
                            .font(.system(size: 12))
                        
                        if isReverseGeocoding {
                            ProgressView().controlSize(.small)
                                .scaleEffect(0.7)
                            Text("Resolving address...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(resolvedPlaceName.isEmpty ? "—" : resolvedPlaceName)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .contextMenu {
                                    Button("Copy Place Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(resolvedPlaceName, forType: .string)
                                    }
                                }
                        }
                    }
                }
                
                Spacer()
                
                // Action Buttons
                HStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    
                    Button("Save Location") {
                        saveLocation()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .controlSize(.large)
                    .disabled(coordinate == nil)
                }
            }
            .padding(20)
            .background(Color.black.opacity(0.2))
        }
        .frame(width: 750, height: 550)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
        .task {
            loadThumbnail()
            
            // If we have a location initially, trigger a reverse geocode update just to confirm it's loaded correctly
            if let coord = coordinate, resolvedPlaceName.isEmpty {
                reverseGeocode(coord)
            }
        }
        // Watch changes using latitude and longitude to bypass CLLocationCoordinate2D conformance warnings
        .onChange(of: coordinate?.latitude) { _, _ in
            guard let newCoord = coordinate else { return }
            reverseGeocode(newCoord)
        }
        .onChange(of: coordinate?.longitude) { _, _ in
            guard let newCoord = coordinate else { return }
            reverseGeocode(newCoord)
        }
    }
    
    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = NSImage(contentsOf: item.fileURL) {
                let size = NSSize(width: 120, height: 120)
                let targetImage = NSImage(size: size)
                targetImage.lockFocus()
                image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
                targetImage.unlockFocus()
                
                DispatchQueue.main.async {
                    self.thumbnail = targetImage
                }
            }
        }
    }
    
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        // Fast path: Check if query is a comma-separated coordinate pair
        let parts = query.components(separatedBy: ",")
        if parts.count == 2,
           let lat = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
           let lon = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            let targetCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            coordinate = targetCoord
            mapCenterNeedUpdate = true
            return
        }
        
        isSearching = true
        
        Task {
            if let location = await GeocodingManager.geocode(address: query) {
                coordinate = location.coordinate
                resolvedPlaceName = location.resolvedName ?? query
                mapCenterNeedUpdate = true
            }
            isSearching = false
        }
    }
    
    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        isReverseGeocoding = true
        Task {
            if let geocoded = await GeocodingManager.reverseGeocode(latitude: coord.latitude, longitude: coord.longitude) {
                resolvedPlaceName = geocoded.resolvedName ?? String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
            } else {
                resolvedPlaceName = String(format: "%.4f, %.4f", coord.latitude, coord.longitude)
            }
            isReverseGeocoding = false
        }
    }
    
    private func saveLocation() {
        guard let coord = coordinate else { return }
        manager.updateItemMetadata(
            id: item.id,
            date: item.detectedDate,
            saveDate: item.saveDate,
            removeDate: item.removeDate,
            place: resolvedPlaceName,
            saveLocation: true,
            removeLocation: false,
            latitude: coord.latitude,
            longitude: coord.longitude,
            geocodedPlace: resolvedPlaceName
        )
    }
}

// MARK: - Map Kit View Wrapper
struct MapEditorViewRepresentable: NSViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D?
    @Binding var mapCenterNeedUpdate: Bool
    
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Double-click gesture to set pin
        let doubleClickGesture = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapDoubleClick(_:)))
        doubleClickGesture.numberOfClicksRequired = 2
        mapView.addGestureRecognizer(doubleClickGesture)
        
        return mapView
    }
    
    func updateNSView(_ nsView: MKMapView, context: Context) {
        context.coordinator.parent = self
        
        // Retrieve existing annotations of type MKPointAnnotation
        let existingAnnotations = nsView.annotations.filter { $0 is MKPointAnnotation }
        
        if let coord = coordinate {
            if let annotation = existingAnnotations.first as? MKPointAnnotation {
                // Update existing annotation coordinate
                if annotation.coordinate.latitude != coord.latitude || annotation.coordinate.longitude != coord.longitude {
                    annotation.coordinate = coord
                }
            } else {
                // Add new annotation
                let annotation = MKPointAnnotation()
                annotation.coordinate = coord
                annotation.title = "Selected Location"
                nsView.addAnnotation(annotation)
            }
            
            if mapCenterNeedUpdate {
                let region = MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                nsView.setRegion(region, animated: true)
                DispatchQueue.main.async {
                    mapCenterNeedUpdate = false
                }
            }
        } else {
            nsView.removeAnnotations(existingAnnotations)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapEditorViewRepresentable
        
        init(_ parent: MapEditorViewRepresentable) {
            self.parent = parent
        }
        
        @objc func handleMapDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            
            DispatchQueue.main.async {
                withAnimation {
                    self.parent.coordinate = coordinate
                }
            }
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let identifier = "SelectedLocationPin"
            var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if annotationView == nil {
                annotationView = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                annotationView?.canShowCallout = false
                annotationView?.isDraggable = true
                annotationView?.markerTintColor = .systemPurple
            } else {
                annotationView?.annotation = annotation
            }
            return annotationView
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending {
                if let newCoord = view.annotation?.coordinate {
                    DispatchQueue.main.async {
                        withAnimation {
                            self.parent.coordinate = newCoord
                        }
                    }
                }
            }
        }
    }
}
