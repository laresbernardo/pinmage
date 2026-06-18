import SwiftUI
import AppKit

struct ProcessView: View {
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    @State private var isDraggingOver = false
    
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
                                        .foregroundColor(.emerald.opacity(0.85))
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
                            Task {
                                await manager.startProcessing(settings: settings)
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Start Processing")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.emerald)
                        .disabled(manager.imageItems.isEmpty)
                        
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
                            .fill(LinearGradient(colors: [.emerald, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(manager.currentProgress), height: 4)
                            .animation(.spring(), value: manager.currentProgress)
                    }
                }
                .frame(height: 4)
            } else {
                Divider().background(Color.white.opacity(0.1))
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
                .background(isDraggingOver ? Color.emerald.opacity(0.05) : Color.clear)
                .onDrop(of: ["public.file-url"], isTargeted: $isDraggingOver) { providers in
                    handleDrop(providers: providers)
                }
            } else {
                List {
                    ForEach(manager.imageItems) { item in
                        QueueRowView(item: item, onRemove: {
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
        .background(isDraggingOver ? Color.emerald.opacity(0.05) : Color.clear)
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
    let onRemove: () -> Void
    @State private var thumbnail: NSImage? = nil
    
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
                        Image(systemName: "calendar")
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
                                .foregroundColor(.emerald)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.emerald.opacity(0.15))
                                .cornerRadius(3)
                        }
                    }
                    
                    // Place output
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.and.ellipse")
                        if let place = item.detectedPlace {
                            Text(place)
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                        } else {
                            Text("Pending...")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Coordinates output
                    if let lat = item.latitude, let lon = item.longitude {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                            Text(String(format: "%.4f, %.4f", lat, lon))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
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
            
            // Row Action Button
            if item.status == .pending || item.status == .failed {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            } else if item.status == .completed, let outputURL = item.outputURL {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }) {
                    Image(systemName: "magnifyingglass.circle")
                        .foregroundColor(.emerald)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .help("Show in Finder")
            }
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
