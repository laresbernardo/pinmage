import SwiftUI
import AppKit

struct ProcessView: View {
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    @State private var isDraggingOver = false
    @State private var showOverwriteAlert = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Processing Header / Actions Panel
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import & Process Queue")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    if manager.isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing: \(manager.currentProcessingFile)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(manager.imageItems.count) files in queue | \(manager.successfulCount) completed, \(manager.failedCount) failed")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            if !manager.imageItems.isEmpty {
                                let pendingCount = manager.imageItems.filter { $0.status == .pending || $0.status == .failed }.count
                                if pendingCount > 0 {
                                    Text("Estimated AI Cost: \(estimatedCostString(count: pendingCount, model: settings.modelName)) (\(pendingCount) pending files)")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(.cyan.opacity(0.85))
                                }
                            }
                        }
                    }
                }
                
                Spacer()
                
                // Action Buttons
                HStack(spacing: 10) {
                    if manager.isProcessing {
                        Button(action: {
                            manager.stopProcessing()
                        }) {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                Text("Cancel")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    } else {
                        Button(action: {
                            selectFiles()
                        }) {
                            HStack {
                                Image(systemName: "plus.circle")
                                Text("Add Images...")
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: {
                            startAnalysisQueue()
                        }) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Analyze Queue")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(manager.imageItems.isEmpty || manager.imageItems.allSatisfy { $0.status == .analyzed || $0.status == .completed })
                        
                        Button(action: {
                            manager.clearAll()
                        }) {
                            Text("Clear")
                        }
                        .buttonStyle(.bordered)
                        .disabled(manager.imageItems.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            
            // Progress Bar
            if manager.isProcessing {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 4)
                        Rectangle()
                            .fill(LinearGradient(colors: [.indigo, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(manager.currentProgress), height: 4)
                            .animation(.spring(), value: manager.currentProgress)
                    }
                }
                .frame(height: 4)
            } else {
                Divider().background(Color.white.opacity(0.1))
            }
            
            // Certainty Threshold Panel
            if !manager.isProcessing, hasAnalyzedItems {
                certaintyThresholdPanel
            }
            
            // Queue List or Empty State
            if manager.imageItems.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary.opacity(0.4))
                    
                    Text("Drag and drop images or directories here")
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Button("Browse Files...") {
                        selectFiles()
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isDraggingOver ? Color.cyan.opacity(0.05) : Color.clear)
                .onDrop(of: ["public.file-url"], isTargeted: $isDraggingOver) { providers in
                    handleDrop(providers: providers)
                }
            } else {
                List {
                    ForEach(manager.imageItems) { item in
                        QueueRowView(item: item, manager: manager, settings: settings, onRemove: {
                            manager.removeImage(id: item.id)
                        })
                        .padding(.vertical, 4)
                        .listRowSeparator(.visible)
                        .listRowSeparatorTint(Color.white.opacity(0.05))
                    }
                }
                .listStyle(.inset)
                .onDrop(of: ["public.file-url"], isTargeted: $isDraggingOver) { providers in
                    handleDrop(providers: providers)
                }
            }
        }
        .background(isDraggingOver ? Color.cyan.opacity(0.05) : Color.clear)
        .alert(isPresented: $showOverwriteAlert) {
            Alert(
                title: Text("Overwrite Original Files?"),
                message: Text("WARNING: Proceeding will replace the source images on your disk with the new date and location metadata. This action cannot be undone. Make sure you have backups!"),
                primaryButton: .destructive(Text("Overwrite Files")) {
                    startWritingQueue()
                },
                secondaryButton: .cancel()
            )
        }
    }
    
    private var hasAnalyzedItems: Bool {
        manager.imageItems.contains { $0.status == .analyzed }
    }
    
    private var dateWillModifyCount: Int {
        manager.imageItems.filter { ($0.status == .analyzed || $0.status == .completed) && $0.saveDate }.count
    }
    
    private var locationWillModifyCount: Int {
        manager.imageItems.filter { ($0.status == .analyzed || $0.status == .completed) && $0.saveLocation }.count
    }
    
    private var certaintyThresholdPanel: some View {
        GlassCard {
            HStack(spacing: 24) {
                // Slider
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Certainty Threshold:")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        Text("\(settings.certaintyThreshold)%")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                    }
                    
                    Slider(
                        value: Binding(
                            get: { Double(settings.certaintyThreshold) },
                            set: { val in
                                settings.certaintyThreshold = Int(val)
                                manager.updateCheckboxes(threshold: Int(val))
                            }
                        ),
                        in: 0...100,
                        step: 5
                    )
                    .tint(.cyan)
                }
                .frame(maxWidth: 320)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                    .frame(height: 40)
                
                // Previews
                VStack(alignment: .leading, spacing: 4) {
                    Text("Certainty Filter Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 16) {
                        Label(
                            "\(dateWillModifyCount) dates to save",
                            systemImage: "calendar"
                        )
                        .font(.subheadline)
                        .foregroundColor(.white)
                        
                        Label(
                            "\(locationWillModifyCount) locations to save",
                            systemImage: "mappin.and.ellipse"
                        )
                        .font(.subheadline)
                        .foregroundColor(.white)
                    }
                }
                
                Spacer()
                
                // Write/Save Button
                Button(action: {
                    if settings.overwriteOriginals {
                        showOverwriteAlert = true
                    } else {
                        startWritingQueue()
                    }
                }) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Save Metadata to Files")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(dateWillModifyCount == 0 && locationWillModifyCount == 0)
            }
            .padding(16)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
    
    private func startAnalysisQueue() {
        Task {
            await manager.startAnalysis(settings: settings)
        }
    }
    
    private func startWritingQueue() {
        Task {
            await manager.startWriting(settings: settings)
        }
    }
    
    private func selectFiles() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Images or Folders"
        openPanel.showsResizeIndicator = true
        openPanel.showsHiddenFiles = false
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [.image, .folder]
        
        if openPanel.runModal() == .OK {
            manager.addImages(urls: openPanel.urls)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                defer { group.leave() }
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
        }
        
        group.notify(queue: .main) {
            if !urls.isEmpty {
                manager.addImages(urls: urls)
            }
        }
        return true
    }
    
    private func estimatedCostString(count: Int, model: String) -> String {
        guard count > 0 else { return "$0.00" }
        
        let isPro = model.contains("pro")
        let inputRate = isPro ? 1.25 : 0.075
        let outputRate = isPro ? 5.00 : 0.30
        
        // Standard image token size in Gemini is 258. Plus text prompt (~150 tokens) -> 408 input tokens per image.
        let inputTokens = Double(count) * 410.0
        // JSON response size is ~80 tokens.
        let outputTokens = Double(count) * 80.0
        
        let cost = (inputTokens * inputRate / 1_000_000.0) + (outputTokens * outputRate / 1_000_000.0)
        
        if cost < 0.01 {
            return "less than $0.01"
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 4
            return formatter.string(from: NSNumber(value: cost)) ?? String(format: "$%.4f", cost)
        }
    }
}

struct QueueRowView: View {
    let item: ImageItem
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    let onRemove: () -> Void
    @State private var thumbnail: NSImage? = nil
    @State private var showingEditPopover = false
    
    var body: some View {
        HStack(spacing: 16) {
            // Image Thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 50, height: 50)
                
                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(.secondary)
                }
            }
            .task {
                loadThumbnail()
            }
            
            // File Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.fileName)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Status Badge
                    HStack(spacing: 4) {
                        Image(systemName: item.status.iconName)
                        Text(item.status.rawValue)
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(item.status.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(item.status.color.opacity(0.12))
                    .cornerRadius(4)
                }
                
                HStack(spacing: 16) {
                    // Date output
                    HStack(spacing: 4) {
                        if item.status == .analyzed || item.status == .completed || item.detectedDate != nil {
                            Button(action: {
                                manager.toggleSaveDate(id: item.id)
                            }) {
                                Image(systemName: item.saveDate ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(item.saveDate ? .emerald : .secondary.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .disabled(item.detectedDate == nil)
                        }
                        
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        if let dateStr = item.detectedDateString {
                            Text(dateStr)
                                .foregroundColor(.white.opacity(0.9))
                        } else if let date = item.detectedDate {
                            Text(formattedDate(date))
                                .foregroundColor(.white.opacity(0.9))
                        } else {
                            Text("Pending...")
                                .foregroundColor(.secondary)
                        }
                        
                        if item.dateIsInherited {
                            Text("(Inherited)")
                                .font(.system(size: 9))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.cyan.opacity(0.15))
                                .cornerRadius(3)
                        }
                        
                        if let certainty = item.dateCertainty {
                            let isAbove = certainty >= settings.certaintyThreshold
                            Text("\(certainty)%")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isAbove ? .cyan : .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((isAbove ? Color.cyan : Color.orange).opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    
                    // Place output
                    HStack(spacing: 4) {
                        if item.status == .analyzed || item.status == .completed || item.detectedPlace != nil {
                            Button(action: {
                                manager.toggleSaveLocation(id: item.id)
                            }) {
                                Image(systemName: item.saveLocation ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(item.saveLocation ? .emerald : .secondary.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .disabled(item.latitude == nil || item.longitude == nil)
                        }
                        
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        
                        if let place = item.detectedPlace {
                            Text(place)
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                        } else {
                            Text("Pending...")
                                .foregroundColor(.secondary)
                        }
                        
                        if let certainty = item.locationCertainty {
                            let isAbove = certainty >= settings.certaintyThreshold
                            Text("\(certainty)%")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isAbove ? .cyan : .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background((isAbove ? Color.cyan : Color.orange).opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    
                    // Coordinates output
                    if let lat = item.latitude, let lon = item.longitude {
                        HStack(alignment: .top, spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(String(format: "%.4f, %.4f", lat, lon))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                if let geoName = item.geocodedPlace {
                                    Text("Ref: \(geoName)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.cyan.opacity(0.8))
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 2)
                }
            }
            
            // Row Action Buttons
            HStack(spacing: 8) {
                if !manager.isProcessing && item.status != .writing {
                    Button(action: {
                        showingEditPopover = true
                    }) {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit details manually")
                    .popover(isPresented: $showingEditPopover, arrowEdge: .trailing) {
                        EditMetadataPopover(item: item, manager: manager)
                    }
                }
                
                if item.status == .pending || item.status == .failed {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                } else if item.status == .completed, let outputURL = item.outputURL {
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
            .padding(.leading, 4)
        }
    }
    
    private func loadThumbnail() {
        // Run asynchronously to avoid blocking UI main thread
        DispatchQueue.global(qos: .userInitiated).async {
            if let image = NSImage(contentsOf: item.fileURL) {
                // Resize image to fit square thumbnail
                let size = NSSize(width: 100, height: 100)
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
    
    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

struct EditMetadataPopover: View {
    let item: ImageItem
    @ObservedObject var manager: PinmageManager
    @Environment(\.dismiss) var dismiss
    
    @State private var useDate: Bool
    @State private var date: Date
    
    @State private var useLocation: Bool
    @State private var place: String
    @State private var latitudeStr: String
    @State private var longitudeStr: String
    @State private var geocodedPlace: String
    
    @State private var isGeocoding = false
    
    init(item: ImageItem, manager: PinmageManager) {
        self.item = item
        self.manager = manager
        
        // Initialize state
        _useDate = State(initialValue: item.saveDate || item.detectedDate != nil)
        _date = State(initialValue: item.detectedDate ?? Date())
        
        _useLocation = State(initialValue: item.saveLocation || item.latitude != nil)
        _place = State(initialValue: item.detectedPlace ?? "")
        _latitudeStr = State(initialValue: item.latitude != nil ? String(format: "%.6f", item.latitude!) : "")
        _longitudeStr = State(initialValue: item.longitude != nil ? String(format: "%.6f", item.longitude!) : "")
        _geocodedPlace = State(initialValue: item.geocodedPlace ?? "")
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Metadata")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(item.fileName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Divider().background(Color.white.opacity(0.1))
            
            VStack(alignment: .leading, spacing: 12) {
                // Date Section
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include Date", isOn: $useDate)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if useDate {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                    }
                }
                
                Divider().background(Color.white.opacity(0.05))
                
                // Location Section
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Include Location", isOn: $useLocation)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    
                    if useLocation {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Place Name")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            HStack {
                                TextField("e.g. Eiffel Tower, Paris", text: $place)
                                    .textFieldStyle(.roundedBorder)
                                
                                Button(action: lookupCoordinates) {
                                    if isGeocoding {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Look Up")
                                    }
                                }
                                .disabled(place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGeocoding)
                            }
                            
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Latitude")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Latitude", text: $latitudeStr)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Longitude")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Longitude", text: $longitudeStr)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            
                            if !geocodedPlace.isEmpty {
                                Text("Resolved: \(geocodedPlace)")
                                    .font(.caption2)
                                    .foregroundColor(.cyan)
                                    .italic()
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
            }
            .frame(width: 280)
            
            Divider().background(Color.white.opacity(0.1))
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Apply") {
                    saveChanges()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func lookupCoordinates() {
        guard !place.isEmpty else { return }
        isGeocoding = true
        Task {
            if let geocoded = await GeocodingManager.geocode(address: place) {
                latitudeStr = String(format: "%.6f", geocoded.coordinate.latitude)
                longitudeStr = String(format: "%.6f", geocoded.coordinate.longitude)
                geocodedPlace = geocoded.resolvedName ?? ""
            }
            isGeocoding = false
        }
    }
    
    private func saveChanges() {
        let finalDate = useDate ? date : nil
        let finalPlace = useLocation && !place.isEmpty ? place : nil
        let finalLat = useLocation ? Double(latitudeStr) : nil
        let finalLon = useLocation ? Double(longitudeStr) : nil
        let finalGeo = useLocation ? geocodedPlace : nil
        
        manager.updateItemMetadata(
            id: item.id,
            date: finalDate,
            saveDate: useDate,
            place: finalPlace,
            saveLocation: useLocation,
            latitude: finalLat,
            longitude: finalLon,
            geocodedPlace: finalGeo
        )
    }
}
