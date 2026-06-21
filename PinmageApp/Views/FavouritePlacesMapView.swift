import SwiftUI
import MapKit

class FavoritePlaceAnnotation: MKPointAnnotation {
    let placeId: UUID
    
    init(placeId: UUID) {
        self.placeId = placeId
        super.init()
    }
}

class TempPlaceAnnotation: MKPointAnnotation {
    override init() {
        super.init()
    }
}

struct FavouritePlacesMapView: View {
    @ObservedObject var settings: AppSettings
    
    @Binding var selectedPlaceId: UUID?
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D?
    @Binding var mapCenterNeedUpdate: Bool
    
    @State private var tempCoordinate: CLLocationCoordinate2D? = nil
    @State private var searchText = ""
    @State private var isSearching = false
    @State private var isReverseGeocoding = false
    
    // Form States
    @State private var editName = ""
    @State private var editLatStr = ""
    @State private var editLonStr = ""
    
    @State private var newName = ""
    @State private var newLatStr = ""
    @State private var newLonStr = ""
    
    var body: some View {
        VStack(spacing: 12) {
            // Map Area with Overlays
            ZStack(alignment: .topTrailing) {
                // Map Component
                FavouritePlacesMapViewRepresentable(
                    settings: settings,
                    selectedPlaceId: $selectedPlaceId,
                    tempCoordinate: $tempCoordinate,
                    mapCenterCoordinate: $mapCenterCoordinate,
                    mapCenterNeedUpdate: $mapCenterNeedUpdate
                )
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                
                // Floating Instructions and Search Bar on Top
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // Search Bar
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                            
                            TextField("Search city or landmark...", text: $searchText)
                                .textFieldStyle(.plain)
                                .foregroundColor(.white)
                                .font(.body)
                                .onSubmit {
                                    performSearch()
                                }
                            
                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .frame(width: 250)
                        
                        Button(action: performSearch) {
                            if isSearching {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Search")
                                    .fontWeight(.medium)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                        
                        Spacer()
                        
                        // Floating Instructions
                        Text("Double-click map to drop a pin")
                            .font(.caption2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.65))
                            .foregroundColor(.white.opacity(0.8))
                            .cornerRadius(6)
                    }
                    .padding(12)
                    
                    Spacer()
                }
                
                // HUD Overlay (Details Panel)
                HStack {
                    Spacer()
                    if let selectedId = selectedPlaceId,
                       let place = settings.favoritePlaces.first(where: { $0.id == selectedId }) {
                        // Edit Existing Place Panel
                        detailsPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Edit Favourite Place")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Button(action: { selectedPlaceId = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Place Name")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Name", text: $editName)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Latitude")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Lat", text: $editLatStr)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Longitude")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Lon", text: $editLonStr)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                HStack(spacing: 8) {
                                    Button(role: .destructive) {
                                        settings.favoritePlaces.removeAll { $0.id == selectedId }
                                        selectedPlaceId = nil
                                    } label: {
                                        Text("Delete")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Spacer()
                                    
                                    Button("Save") {
                                        saveExistingChanges(placeId: selectedId)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.cyan)
                                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                              Double(editLatStr.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ||
                                              Double(editLonStr.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                                }
                            }
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .onAppear {
                            editName = place.name
                            editLatStr = String(format: "%.6f", place.latitude)
                            editLonStr = String(format: "%.6f", place.longitude)
                        }
                        .onChange(of: selectedPlaceId) { _, newId in
                            if let newId = newId, let newPlace = settings.favoritePlaces.first(where: { $0.id == newId }) {
                                editName = newPlace.name
                                editLatStr = String(format: "%.6f", newPlace.latitude)
                                editLonStr = String(format: "%.6f", newPlace.longitude)
                            }
                        }
                    } else if let tempCoord = tempCoordinate {
                        // Add New Place Panel
                        detailsPanel {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("New Favourite Place")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Button(action: { tempCoordinate = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                if isReverseGeocoding {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("Reverse geocoding...")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.vertical, 8)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Place Name")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Name", text: $newName)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Latitude")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Lat", text: $newLatStr)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Longitude")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Lon", text: $newLonStr)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                                Divider().background(Color.white.opacity(0.1))
                                
                                HStack {
                                    Button("Cancel") {
                                        tempCoordinate = nil
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Spacer()
                                    
                                    Button("Add Place") {
                                        addNewPlace()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.cyan)
                                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                              Double(newLatStr.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ||
                                              Double(newLonStr.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                                }
                            }
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .onAppear {
                            newName = ""
                            newLatStr = String(format: "%.6f", tempCoord.latitude)
                            newLonStr = String(format: "%.6f", tempCoord.longitude)
                            reverseGeocode(tempCoord)
                        }
                        .onChange(of: tempCoordinate?.latitude) { _, _ in
                            guard let tc = tempCoordinate else { return }
                            newLatStr = String(format: "%.6f", tc.latitude)
                            newLonStr = String(format: "%.6f", tc.longitude)
                            reverseGeocode(tc)
                        }
                        .onChange(of: tempCoordinate?.longitude) { _, _ in
                            guard let tc = tempCoordinate else { return }
                            newLatStr = String(format: "%.6f", tc.latitude)
                            newLonStr = String(format: "%.6f", tc.longitude)
                            reverseGeocode(tc)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    @ViewBuilder
    private func detailsPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: 280)
            .background(
                ZStack {
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                    
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
            )
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
    
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        // Fast path for coordinate pair search
        let parts = query.components(separatedBy: ",")
        if parts.count == 2,
           let lat = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
           let lon = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            let targetCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            selectedPlaceId = nil
            tempCoordinate = targetCoord
            mapCenterCoordinate = targetCoord
            mapCenterNeedUpdate = true
            return
        }
        
        isSearching = true
        Task {
            if let location = await GeocodingManager.geocode(address: query) {
                selectedPlaceId = nil
                tempCoordinate = location.coordinate
                mapCenterCoordinate = location.coordinate
                mapCenterNeedUpdate = true
                newName = location.resolvedName ?? query
            }
            isSearching = false
        }
    }
    
    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        isReverseGeocoding = true
        Task {
            if let geocoded = await GeocodingManager.reverseGeocode(latitude: coord.latitude, longitude: coord.longitude) {
                newName = geocoded.resolvedName ?? ""
            } else {
                newName = ""
            }
            isReverseGeocoding = false
        }
    }
    
    private func saveExistingChanges(placeId: UUID) {
        guard let lat = Double(editLatStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(editLonStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        
        if let idx = settings.favoritePlaces.firstIndex(where: { $0.id == placeId }) {
            settings.favoritePlaces[idx].name = editName
            settings.favoritePlaces[idx].latitude = lat
            settings.favoritePlaces[idx].longitude = lon
            selectedPlaceId = nil
        }
    }
    
    private func addNewPlace() {
        guard let lat = Double(newLatStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lon = Double(newLonStr.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        
        let newPlace = FavoritePlace(name: newName, latitude: lat, longitude: lon)
        settings.favoritePlaces.append(newPlace)
        tempCoordinate = nil
    }
}

// MARK: - Map Kit View Wrapper
struct FavouritePlacesMapViewRepresentable: NSViewRepresentable {
    @ObservedObject var settings: AppSettings
    @Binding var selectedPlaceId: UUID?
    @Binding var tempCoordinate: CLLocationCoordinate2D?
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D?
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
        
        // 1. Reconcile existing pins
        let existingAnnotations = nsView.annotations.compactMap { $0 as? FavoritePlaceAnnotation }
        
        for place in settings.favoritePlaces {
            let coord = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            if let existing = existingAnnotations.first(where: { $0.placeId == place.id }) {
                // Update properties if changed
                if existing.coordinate.latitude != coord.latitude || existing.coordinate.longitude != coord.longitude {
                    existing.coordinate = coord
                }
                if existing.title != place.name {
                    existing.title = place.name
                }
                existing.subtitle = String(format: "%.6f, %.6f", place.latitude, place.longitude)
            } else {
                let annotation = FavoritePlaceAnnotation(placeId: place.id)
                annotation.coordinate = coord
                annotation.title = place.name
                annotation.subtitle = String(format: "%.6f, %.6f", place.latitude, place.longitude)
                nsView.addAnnotation(annotation)
            }
        }
        
        // Remove any annotations that no longer exist
        let currentIds = Set(settings.favoritePlaces.map { $0.id })
        let removed = existingAnnotations.filter { !currentIds.contains($0.placeId) }
        if !removed.isEmpty {
            nsView.removeAnnotations(removed)
        }
        
        // 2. Reconcile temporary pin
        let existingTemp = nsView.annotations.compactMap { $0 as? TempPlaceAnnotation }
        if let tempCoord = tempCoordinate {
            if let tempAnn = existingTemp.first {
                if tempAnn.coordinate.latitude != tempCoord.latitude || tempAnn.coordinate.longitude != tempCoord.longitude {
                    tempAnn.coordinate = tempCoord
                }
            } else {
                let tempAnn = TempPlaceAnnotation()
                tempAnn.coordinate = tempCoord
                tempAnn.title = "Dropped Pin"
                tempAnn.subtitle = "Double-click to relocate"
                nsView.addAnnotation(tempAnn)
                nsView.selectAnnotation(tempAnn, animated: true)
            }
        } else {
            if !existingTemp.isEmpty {
                nsView.removeAnnotations(existingTemp)
            }
        }
        
        // 3. Pan map if triggered
        if mapCenterNeedUpdate, let center = mapCenterCoordinate {
            let region = MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            nsView.setRegion(region, animated: true)
            DispatchQueue.main.async {
                mapCenterNeedUpdate = false
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FavouritePlacesMapViewRepresentable
        
        init(_ parent: FavouritePlacesMapViewRepresentable) {
            self.parent = parent
        }
        
        @objc func handleMapDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard gesture.state == .ended else { return }
            guard let mapView = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)
            
            DispatchQueue.main.async {
                withAnimation {
                    self.parent.selectedPlaceId = nil
                    self.parent.tempCoordinate = coordinate
                }
            }
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            
            if let favAnn = annotation as? FavoritePlaceAnnotation {
                let identifier = "FavoritePlacePin"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: favAnn, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = false
                    annotationView?.isDraggable = true
                    annotationView?.markerTintColor = .systemPink
                    annotationView?.glyphImage = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: "Favorite Place")
                } else {
                    annotationView?.annotation = favAnn
                }
                return annotationView
            } else if let tempAnn = annotation as? TempPlaceAnnotation {
                let identifier = "TempPlacePin"
                var annotationView = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                
                if annotationView == nil {
                    annotationView = MKMarkerAnnotationView(annotation: tempAnn, reuseIdentifier: identifier)
                    annotationView?.canShowCallout = false
                    annotationView?.isDraggable = true
                    annotationView?.markerTintColor = .systemPurple
                    annotationView?.glyphImage = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Pin")
                } else {
                    annotationView?.annotation = tempAnn
                }
                return annotationView
            }
            
            return nil
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation else { return }
            
            DispatchQueue.main.async {
                withAnimation {
                    if let favAnn = annotation as? FavoritePlaceAnnotation {
                        self.parent.selectedPlaceId = favAnn.placeId
                        self.parent.tempCoordinate = nil
                    } else if annotation is TempPlaceAnnotation {
                        self.parent.selectedPlaceId = nil
                    }
                }
            }
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending {
                guard let annotation = view.annotation else { return }
                let newCoord = annotation.coordinate
                
                if let favAnn = annotation as? FavoritePlaceAnnotation {
                    let placeId = favAnn.placeId
                    DispatchQueue.main.async {
                        if let index = self.parent.settings.favoritePlaces.firstIndex(where: { $0.id == placeId }) {
                            self.parent.settings.favoritePlaces[index].latitude = newCoord.latitude
                            self.parent.settings.favoritePlaces[index].longitude = newCoord.longitude
                        }
                    }
                } else if annotation is TempPlaceAnnotation {
                    DispatchQueue.main.async {
                        self.parent.tempCoordinate = newCoord
                    }
                }
            }
        }
    }
}

struct FavouritePlacesMapExplorerView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss
    
    @Binding var selectedPlaceId: UUID?
    @Binding var mapCenterCoordinate: CLLocationCoordinate2D?
    @Binding var mapCenterNeedUpdate: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Favourite Places Map Explorer")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Double-click map or search to drop a pin. Drag pins to adjust coordinates.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.black.opacity(0.2))
            
            Divider().background(Color.white.opacity(0.1))
            
            // Map Explorer
            FavouritePlacesMapView(
                settings: settings,
                selectedPlaceId: $selectedPlaceId,
                mapCenterCoordinate: $mapCenterCoordinate,
                mapCenterNeedUpdate: $mapCenterNeedUpdate
            )
            .padding(16)
        }
        .frame(width: 850, height: 620)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow))
    }
}
