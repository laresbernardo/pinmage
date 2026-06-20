import SwiftUI
import AppKit

struct ProcessView: View {
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    @State private var isDraggingOver = false
    @State private var showOverwriteAlert = false
    @State private var elapsedTime: TimeInterval = 0
    @State private var selectedIds: Set<UUID> = []
    @State private var showingBatchEdit = false
    
    @State private var selectedMapItem: ImageItem? = nil
    @State private var isProcessingOptionsExpanded = false
    @State private var isCertaintyPanelExpanded = false
    
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
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Processing: \(manager.currentProcessingFile)")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                    Text(elapsedTimeString)
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                                Text("\(manager.totalProcessedCount) / \(manager.imageItems.count) files | \(manager.successfulCount) OK, \(manager.failedCount) failed")
                                    .font(.caption)
                                    .foregroundColor(.secondary.opacity(0.7))
                                if manager.sessionSpend > 0 {
                                    Text("Cost: \(formattedCost(manager.sessionSpend))")
                                        .font(.caption)
                                        .foregroundColor(.emerald.opacity(0.7))
                                }
                            }
                        }
                        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                            if manager.isProcessing {
                                elapsedTime += 1
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(manager.imageItems.count) files in queue | \(manager.successfulCount) completed, \(manager.failedCount) failed")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            HStack(spacing: 12) {
                                if !manager.imageItems.isEmpty {
                                    let pendingCount = manager.imageItems.filter { $0.status == .pending || $0.status == .failed }.count
                                    if pendingCount > 0 {
                                        Text("Estimated: \(estimatedCostString(count: pendingCount, model: settings.modelName)) (\(pendingCount) pending)")
                                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                                            .foregroundColor(.cyan.opacity(0.85))
                                    }
                                }
                                
                                if manager.sessionSpend > 0 {
                                    Text("Actual: \(formattedCost(manager.sessionSpend))")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(.emerald.opacity(0.85))
                                }
                                
                                if settings.cumulativeSpend > 0 {
                                    Text("Total: \(formattedCost(settings.cumulativeSpend))")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                                
                                if let batchDuration = manager.batchDuration {
                                    HStack(spacing: 3) {
                                        Image(systemName: "clock")
                                            .font(.system(size: 9))
                                        Text("Time: \(formattedDuration(batchDuration))")
                                    }
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary.opacity(0.6))
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
                            manager.pauseProcessing()
                        }) {
                            HStack {
                                Image(systemName: "pause.circle.fill")
                                Text("Pause")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

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
                                Text("Add Images")
                            }
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: {
                            startAnalysisQueue()
                        }) {
                            HStack {
                                Image(systemName: manager.isPaused ? "play.circle.fill" : "sparkles")
                                Text(manager.isPaused ? "Resume" : "Process")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(manager.imageItems.isEmpty || manager.imageItems.allSatisfy { $0.status == .analyzed || $0.status == .completed })
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
            
            // Import & Processing Options Card
            if !manager.isProcessing, !manager.imageItems.isEmpty {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption)
                                    .foregroundColor(.cyan)
                                Text("Processing Options")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                            Spacer()
                            Image(systemName: isProcessingOptionsExpanded ? "chevron.up" : "chevron.down")
                                .foregroundColor(.secondary)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation {
                                isProcessingOptionsExpanded.toggle()
                            }
                        }
                        
                        if isProcessingOptionsExpanded {
                            Divider().background(Color.white.opacity(0.08))
                            
                            // Processing Mode Selection
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Metadata to Extract")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fontWeight(.semibold)
                                
                                Picker("", selection: $settings.processingMode) {
                                    ForEach(ProcessingMode.allCases) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .frame(maxWidth: 320)
                            }
                            .padding(.bottom, 4)
                            
                            Divider().background(Color.white.opacity(0.08))
                            
                            // Option 1: Existing GPS Toggle
                            let gpsCount = manager.imageItems.filter { $0.hasExistingCoordinates }.count
                            if gpsCount > 0 {
                                HStack {
                                    Toggle("Keep existing GPS for \(gpsCount) image(s) — disable to allow AI overwrite", isOn: $settings.skipExistingCoordinates)
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                    Spacer()
                                }
                            }
                            
                            // Option 2: Date extrapolation controls
                            if hasAnalyzedItems {
                                HStack {
                                    Toggle("Extrapolate dates forward (repeat last known date for unknown dates)", isOn: $settings.extrapolateDates)
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .toggleStyle(.switch)
                                        .controlSize(.small)
                                        .onChange(of: settings.extrapolateDates) { _, newValue in
                                            if newValue {
                                                manager.applyDateExtrapolation()
                                            }
                                        }
                                    
                                    if settings.extrapolateDates {
                                        Button("Apply Now") {
                                            manager.applyDateExtrapolation()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                    
                                    Spacer()
                                }
                            }
                            
                            // Option 3: Global Hint Textfield
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "map.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Optional date/location hint (e.g. \"Trip to Italy, 1991\")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                HStack {
                                    TextField("Trip details, year, or country context...", text: $settings.locationHint)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                        .foregroundColor(.white)
                                        .disableAutocorrection(false)
                                    
                                    if !settings.locationHint.isEmpty {
                                        Button(action: { settings.locationHint = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            
            // Selection toolbar
            if !manager.isProcessing, !manager.imageItems.isEmpty {
                HStack {
                    Toggle(isOn: Binding(
                        get: { selectedIds.count == manager.imageItems.count },
                        set: { if $0 { selectedIds = Set(manager.imageItems.map(\.id)) } else { selectedIds = [] } }
                    )) {
                        Text("Select All")
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    
                    if !selectedIds.isEmpty {
                        Button("Batch Edit (\(selectedIds.count))") {
                            showingBatchEdit = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .popover(isPresented: $showingBatchEdit, arrowEdge: .bottom) {
                            BatchEditPopover(ids: selectedIds, manager: manager, settings: settings)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        manager.clearAll()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear Queue")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 8)
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
                        QueueRowView(item: item, manager: manager, settings: settings, selectedIds: $selectedIds, onRemove: {
                            manager.removeImage(id: item.id)
                        }, onEditLocation: {
                            selectedMapItem = item
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
        .onChange(of: manager.isProcessing) { _, newValue in
            if newValue {
                elapsedTime = 0
            }
        }
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
        .sheet(item: $selectedMapItem) { item in
            InteractiveMapEditorView(item: item, manager: manager, settings: settings)
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
    
    private var dateWillRemoveCount: Int {
        manager.imageItems.filter { ($0.status == .analyzed || $0.status == .completed) && $0.removeDate }.count
    }
    
    private var locationWillRemoveCount: Int {
        manager.imageItems.filter { ($0.status == .analyzed || $0.status == .completed) && $0.removeLocation }.count
    }
    
    private var certaintyThresholdPanel: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle")
                            .font(.caption)
                            .foregroundColor(.cyan)
                        Text("Certainty Threshold & Save")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation {
                            isCertaintyPanelExpanded.toggle()
                        }
                    }
                    
                    Spacer()
                    
                    if !isCertaintyPanelExpanded {
                        // Quick-save button when collapsed
                        Button(action: {
                            if settings.overwriteOriginals {
                                showOverwriteAlert = true
                            } else {
                                startWritingQueue()
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Save Metadata")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .controlSize(.small)
                        .disabled(
                            (settings.processingMode == .dateOnly && dateWillModifyCount == 0 && dateWillRemoveCount == 0) ||
                            (settings.processingMode == .locationOnly && locationWillModifyCount == 0 && locationWillRemoveCount == 0) ||
                            (settings.processingMode == .both && dateWillModifyCount == 0 && locationWillModifyCount == 0 && dateWillRemoveCount == 0 && locationWillRemoveCount == 0)
                        )
                    }
                    
                    Button(action: {
                        withAnimation {
                            isCertaintyPanelExpanded.toggle()
                        }
                    }) {
                        Image(systemName: isCertaintyPanelExpanded ? "chevron.up" : "chevron.down")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                
                if isCertaintyPanelExpanded {
                    Divider().background(Color.white.opacity(0.08))
                    
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
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fontWeight(.semibold)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                if settings.processingMode == .both || settings.processingMode == .dateOnly {
                                    Label(
                                        "\(dateWillModifyCount) dates to save",
                                        systemImage: "calendar"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    
                                    if dateWillRemoveCount > 0 {
                                        Label(
                                            "\(dateWillRemoveCount) dates to delete",
                                            systemImage: "calendar.badge.minus"
                                        )
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    }
                                }
                                
                                if settings.processingMode == .both || settings.processingMode == .locationOnly {
                                    Label(
                                        "\(locationWillModifyCount) locations to save",
                                        systemImage: "mappin.and.ellipse"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.white)
                                    
                                    if locationWillRemoveCount > 0 {
                                        Label(
                                            "\(locationWillRemoveCount) locations to delete",
                                            systemImage: "mappin.slash"
                                        )
                                        .font(.caption)
                                        .foregroundColor(.red)
                                    }
                                }
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
                        .disabled(
                            (settings.processingMode == .dateOnly && dateWillModifyCount == 0 && dateWillRemoveCount == 0) ||
                            (settings.processingMode == .locationOnly && locationWillModifyCount == 0 && locationWillRemoveCount == 0) ||
                            (settings.processingMode == .both && dateWillModifyCount == 0 && locationWillModifyCount == 0 && dateWillRemoveCount == 0 && locationWillRemoveCount == 0)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
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
        // showsResizeIndicator is deprecated and no longer functional
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
    
    private var elapsedTimeString: String {
        let minutes = Int(elapsedTime) / 60
        let seconds = Int(elapsedTime) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }

    private func formattedCost(_ value: Double) -> String {
        if value < 0.01 {
            return "less than $0.01"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.4f", value)
    }

    private func estimatedCostString(count: Int, model: String) -> String {
        guard count > 0 else { return "$0.00" }
        
        if settings.provider == .ollama {
            return "Free (Local)"
        }
        
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
    
    private func formattedDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return String(format: "%dm %ds", minutes, seconds)
        }
    }
}

struct QueueRowView: View {
    let item: ImageItem
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    @Binding var selectedIds: Set<UUID>
    let onRemove: () -> Void
    let onEditLocation: () -> Void
    @State private var thumbnail: NSImage? = nil
    @State private var showingEditPopover = false
    @State private var showingPreviewPopover = false
    @State private var isCached: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left: Checkbox & Thumbnail
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { selectedIds.contains(item.id) },
                    set: { if $0 { selectedIds.insert(item.id) } else { selectedIds.remove(item.id) } }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("Select for batch edit")
                
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
                .contentShape(Rectangle())
                .onTapGesture {
                    showingPreviewPopover = true
                }
                .help("Click to enlarge")
                .popover(isPresented: $showingPreviewPopover, arrowEdge: .leading) {
                    ImagePreviewPopover(fileURL: item.fileURL)
                }
                .task {
                    loadThumbnail()
                }
            }
            .alignmentGuide(.top) { d in d[.top] }
            
            // Center Column: File details, Date, Place, and Hint
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.fileName)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
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
                    
                    // Per-item duration
                    if let duration = item.processingDuration {
                        Text(formattedDuration(duration))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                
                // Stack Date & Place vertically to prevent squishing
                VStack(alignment: .leading, spacing: 4) {
                    // Date output
                    if settings.processingMode == .both || settings.processingMode == .dateOnly {
                        HStack(spacing: 6) {
                            let isPending = item.status == .pending || item.status == .processing || item.status == .callingAPI
                            let hasVal = (item.detectedDateString != nil && item.detectedDateString!.lowercased() != "null" && !item.detectedDateString!.isEmpty) || item.detectedDate != nil
                            
                            if item.status == .analyzed || item.status == .completed {
                                if item.removeDate {
                                    Button(action: {
                                        manager.updateItemMetadata(
                                            id: item.id,
                                            date: item.detectedDate,
                                            saveDate: false,
                                            removeDate: false,
                                            place: item.detectedPlace,
                                            saveLocation: item.saveLocation,
                                            removeLocation: item.removeLocation,
                                            latitude: item.latitude,
                                            longitude: item.longitude,
                                            geocodedPlace: item.geocodedPlace
                                        )
                                    }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "arrow.counterclockwise")
                                                .font(.system(size: 8))
                                            Text("Restore")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Click to restore date metadata tag")
                                } else {
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
                            }
                            
                            Button(action: {
                                if item.status != .processing && item.status != .callingAPI && item.status != .geocoding && item.status != .writing {
                                    showingEditPopover = true
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "calendar")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .frame(width: 12, alignment: .center)
                                    
                                    if item.removeDate {
                                        Text("Date will be deleted from image EXIF")
                                            .foregroundColor(.red.opacity(0.8))
                                            .italic()
                                    } else if isPending {
                                        Text("Pending...")
                                            .foregroundColor(.secondary)
                                    } else if let dateStr = item.detectedDateString, dateStr.lowercased() != "null", !dateStr.isEmpty {
                                        Text(dateStr)
                                            .foregroundColor(.white.opacity(0.9))
                                    } else if let date = item.detectedDate {
                                        Text(formattedDate(date))
                                            .foregroundColor(.white.opacity(0.9))
                                    } else {
                                        Text("—")
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Click to edit date manually")
                            .disabled(item.status == .processing || item.status == .callingAPI || item.status == .geocoding || item.status == .writing)
                            
                            // "Why?" popover for date explanation
                            if let explanation = item.dateExplanation, !explanation.isEmpty, hasVal && !item.removeDate {
                                ExplanationWhyButton(title: "Date Explanation", explanation: explanation)
                            }
                            
                            if item.dateIsInherited && !item.removeDate {
                                Text("(Inherited)")
                                    .font(.system(size: 9))
                                    .foregroundColor(.cyan)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.cyan.opacity(0.15))
                                    .cornerRadius(3)
                            }
                            
                            if let certainty = item.dateCertainty, hasVal && !item.removeDate {
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
                    }
                    
                    // Place output
                    if settings.processingMode == .both || settings.processingMode == .locationOnly {
                        HStack(spacing: 6) {
                            let isPending = item.status == .pending || item.status == .processing || item.status == .callingAPI || item.status == .geocoding
                            let hasPlaceVal = (item.detectedPlace != nil && item.detectedPlace!.lowercased() != "null" && !item.detectedPlace!.isEmpty) ||
                                              (settings.skipExistingCoordinates && item.geocodedPlace != nil && item.geocodedPlace!.lowercased() != "null" && !item.geocodedPlace!.isEmpty)
                            
                            if item.status == .analyzed || item.status == .completed {
                                if item.removeLocation {
                                    Button(action: {
                                        manager.updateItemMetadata(
                                            id: item.id,
                                            date: item.detectedDate,
                                            saveDate: item.saveDate,
                                            removeDate: item.removeDate,
                                            place: item.detectedPlace,
                                            saveLocation: false,
                                            removeLocation: false,
                                            latitude: item.latitude,
                                            longitude: item.longitude,
                                            geocodedPlace: item.geocodedPlace
                                        )
                                    }) {
                                        HStack(spacing: 3) {
                                            Image(systemName: "arrow.counterclockwise")
                                                .font(.system(size: 8))
                                            Text("Restore")
                                                .font(.system(size: 9, weight: .bold))
                                        }
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.white.opacity(0.08))
                                        .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Click to restore location metadata tag")
                                } else {
                                    Button(action: {
                                        manager.toggleSaveLocation(id: item.id)
                                    }) {
                                        Image(systemName: item.saveLocation ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(item.saveLocation ? .emerald : .secondary.opacity(0.4))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(item.latitude == nil && !item.hasExistingCoordinates)
                                }
                            }
                            
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .frame(width: 12, alignment: .center)
                            
                            if item.removeLocation {
                                Text("GPS location will be deleted from image EXIF")
                                    .foregroundColor(.red.opacity(0.8))
                                    .italic()
                            } else if isPending {
                                Text("Pending...")
                                    .foregroundColor(.secondary)
                            } else if let place = item.detectedPlace, place.lowercased() != "null", !place.isEmpty {
                                Button(place) {
                                    onEditLocation()
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                                .help("Pin location on map")
                                .contextMenu {
                                    Button("Copy Place Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(place, forType: .string)
                                    }
                                }
                            } else if settings.skipExistingCoordinates, let geo = item.geocodedPlace, geo.lowercased() != "null", !geo.isEmpty {
                                Button(geo) {
                                    onEditLocation()
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.cyan.opacity(0.85))
                                .lineLimit(1)
                                .help("Pin location on map")
                                .contextMenu {
                                    Button("Copy Place Name") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(geo, forType: .string)
                                    }
                                }
                            } else {
                                Text("—")
                                    .foregroundColor(.secondary)
                            }
                            
                            // "Why?" popover for location explanation
                            if let explanation = item.locationExplanation, !explanation.isEmpty, hasPlaceVal && !item.removeLocation {
                                ExplanationWhyButton(title: "Location Explanation", explanation: explanation)
                            }
                            
                            if let certainty = item.locationCertainty, hasPlaceVal && !item.removeLocation {
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
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                
                // Per-image hint
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                    TextField("Optional hint for the AI...", text: Binding(
                        get: { item.hint },
                        set: { manager.updateItemHint(id: item.id, hint: $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .disabled(manager.isProcessing)
                    
                    if !item.hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button(action: {
                            Task {
                                await manager.reprocessSingleItem(id: item.id, settings: settings)
                            }
                        }) {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 11))
                                Text("Reprocess")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundColor(.cyan)
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.isProcessing)
                        .transition(.opacity.combined(with: .scale))
                        .help("Invalidates cache and re-analyzes this image using the custom hint")
                    }
                }
                .padding(.top, 2)
                .animation(.spring(), value: item.hint.isEmpty)
                
                if let error = item.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                }
            }
            
            Spacer()
            
            // Right Column: Coordinates and Action buttons
            VStack(alignment: .trailing, spacing: 6) {
                // Coordinates section
                if settings.processingMode == .both || settings.processingMode == .locationOnly {
                    let hasExisting = item.existingLatitude != nil && item.existingLongitude != nil
                    let hasSuggested = item.latitude != nil && item.longitude != nil
                    let coordsDiffer: Bool = {
                        guard let eLat = item.existingLatitude, let eLon = item.existingLongitude,
                               let sLat = item.latitude, let sLon = item.longitude else { return true }
                        return abs(eLat - sLat) > 0.0001 || abs(eLon - sLon) > 0.0001
                    }()
                    
                    if hasExisting && hasSuggested && coordsDiffer {
                        VStack(alignment: .trailing, spacing: 2) {
                            coordinateRow(label: "Original:", lat: item.existingLatitude!, lon: item.existingLongitude!, color: .secondary)
                            coordinateRow(label: "Suggested:", lat: item.latitude!, lon: item.longitude!, color: .cyan)
                        }
                    } else if let lat = item.latitude ?? item.existingLatitude,
                               let lon = item.longitude ?? item.existingLongitude {
                        let label = hasExisting && !hasSuggested ? "Original:" : "Coords:"
                        coordinateRow(label: label, lat: lat, lon: lon, color: .secondary)
                    }
                }
                
                // Align Action Buttons at the bottom-right of the row
                HStack(spacing: 8) {
                    if item.status != .processing && item.status != .callingAPI && item.status != .geocoding && item.status != .writing {
                        
                        // Show in Finder
                        if item.status == .completed, let outputURL = item.outputURL {
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
                            EditMetadataPopover(item: item, manager: manager, settings: settings, onOpenMap: onEditLocation)
                        }
                        
                        if settings.processingMode == .both || settings.processingMode == .locationOnly {
                            Button(action: {
                                onEditLocation()
                            }) {
                                Image(systemName: "map.circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Pin location on map")
                        }
                        
                        // Cache indicator / Clear button OR Remove from queue
                        if isCached {
                            Button(action: {
                                manager.clearItemCache(id: item.id)
                                isCached = false
                            }) {
                                Image(systemName: "bolt.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.yellow)
                            }
                            .buttonStyle(.plain)
                            .help("Clear cached AI result for this image")
                        } else {
                            // Remove from queue
                            Button(action: onRemove) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove from queue")
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(minWidth: 170, alignment: .trailing)
        }
        .onAppear {
            isCached = !item.cacheHash.isEmpty && CacheManager.shared.hasCache(hash: item.cacheHash)
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
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    
    private func formattedDuration(_ interval: TimeInterval) -> String {
        if interval < 60 {
            return String(format: "%.1fs", interval)
        } else {
            let minutes = Int(interval) / 60
            let seconds = Int(interval) % 60
            return String(format: "%dm %ds", minutes, seconds)
        }
    }
    
    private func coordinateRow(label: String, lat: Double, lon: Double, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(color)
            Button(String(format: "%.4f, %.4f", lat, lon)) {
                onEditLocation()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(color)
            .help("Pin location on map")
            .fixedSize(horizontal: true, vertical: false)
            .contextMenu {
                Button("Copy Coordinates") {
                    let text = String(format: "%.6f, %.6f", lat, lon)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }
}

struct EditMetadataPopover: View {
    let item: ImageItem
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    let onOpenMap: () -> Void
    @Environment(\.dismiss) var dismiss
    
    // Three states: 0 = Save/Write, 1 = Keep Original, 2 = Remove/Strip
    @State private var dateAction: Int
    
    // Three states: 0 = Save/Write, 1 = Keep Original, 2 = Remove/Strip
    @State private var locationAction: Int
    
    @State private var useDate: Bool
    @State private var date: Date
    
    @State private var useLocation: Bool
    @State private var place: String
    @State private var latitudeStr: String
    @State private var longitudeStr: String
    @State private var geocodedPlace: String
    
    @State private var isGeocoding = false
    
    @State private var hintText: String
    
    init(item: ImageItem, manager: PinmageManager, settings: AppSettings, onOpenMap: @escaping () -> Void) {
        self.item = item
        self.manager = manager
        self.settings = settings
        self.onOpenMap = onOpenMap
        
        // Initialize state
        let initDateAction = item.removeDate ? 2 : (item.saveDate || item.detectedDate != nil ? 0 : 1)
        _dateAction = State(initialValue: initDateAction)
        _useDate = State(initialValue: initDateAction == 0)
        _date = State(initialValue: item.detectedDate ?? Date())
        
        let initLocAction = item.removeLocation ? 2 : (item.saveLocation || item.latitude != nil ? 0 : 1)
        _locationAction = State(initialValue: initLocAction)
        _useLocation = State(initialValue: initLocAction == 0)
        _place = State(initialValue: item.detectedPlace ?? "")
        _latitudeStr = State(initialValue: item.latitude != nil ? String(format: "%.6f", item.latitude!) : "")
        _longitudeStr = State(initialValue: item.longitude != nil ? String(format: "%.6f", item.longitude!) : "")
        _geocodedPlace = State(initialValue: item.geocodedPlace ?? "")
        _hintText = State(initialValue: item.hint)
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
                if settings.processingMode == .both || settings.processingMode == .dateOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Date Metadata Action")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Picker("", selection: $dateAction) {
                            Text("Save Date").tag(0)
                            Text("Keep Original").tag(1)
                            Text("Remove Date").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        
                        if dateAction == 0 {
                            DatePicker("", selection: $date, displayedComponents: .date)
                                .datePickerStyle(.field)
                                .labelsHidden()
                                .padding(.top, 4)
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                }
                
                // Location Section
                if settings.processingMode == .both || settings.processingMode == .locationOnly {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Location Metadata Action")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        
                        Picker("", selection: $locationAction) {
                            Text("Save Coords").tag(0)
                            Text("Keep Original").tag(1)
                            Text("Remove Loc").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        
                        if locationAction == 0 {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Place Name")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    
                                    if !settings.favoritePlaces.isEmpty {
                                        Spacer()
                                        Menu {
                                            ForEach(settings.favoritePlaces) { fav in
                                                Button(fav.name) {
                                                    place = fav.name
                                                    latitudeStr = String(format: "%.6f", fav.latitude)
                                                    longitudeStr = String(format: "%.6f", fav.longitude)
                                                    geocodedPlace = fav.name
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 3) {
                                                Image(systemName: "heart.fill")
                                                    .foregroundColor(.red)
                                                    .font(.system(size: 9))
                                                Text("Choose Favourite")
                                                    .font(.caption2)
                                            }
                                        }
                                        .menuStyle(.borderlessButton)
                                    }
                                }
                                
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
                                            .onChange(of: latitudeStr) { _, newValue in
                                                handleCoordinatePaste(newValue)
                                            }
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Longitude")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("Longitude", text: $longitudeStr)
                                            .textFieldStyle(.roundedBorder)
                                            .onChange(of: longitudeStr) { _, newValue in
                                                handleCoordinatePaste(newValue)
                                            }
                                    }
                                }
                                
                                if !geocodedPlace.isEmpty {
                                    Text("Resolved: \(geocodedPlace)")
                                        .font(.caption2)
                                        .foregroundColor(.cyan)
                                        .italic()
                                }
                                
                                Button(action: {
                                    dismiss()
                                    onOpenMap()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "map")
                                        Text("Open Map Pin Editor")
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.cyan)
                                .font(.caption)
                                .padding(.top, 4)
                            }
                            .padding(.leading, 16)
                            .padding(.top, 4)
                        }
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                }
                
                // Hint Section
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("AI Hint")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    TextField("Optional hint to help the AI...", text: $hintText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
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
    
    private func handleCoordinatePaste(_ input: String) {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.components(separatedBy: ",")
        if parts.count == 2 {
            let latVal = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let lonVal = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if Double(latVal) != nil && Double(lonVal) != nil {
                latitudeStr = latVal
                longitudeStr = lonVal
            }
        }
    }
    
    private func saveChanges() {
        let saveDateVal = dateAction == 0
        let removeDateVal = dateAction == 2
        
        let saveLocVal = locationAction == 0
        let removeLocVal = locationAction == 2
        
        let finalDate = saveDateVal ? date : nil
        let finalPlace = saveLocVal && !place.isEmpty ? place : nil
        let finalLat = saveLocVal ? Double(latitudeStr) : nil
        let finalLon = saveLocVal ? Double(longitudeStr) : nil
        let finalGeo = saveLocVal ? geocodedPlace : nil
        
        manager.updateItemMetadata(
            id: item.id,
            date: settings.processingMode == .locationOnly ? nil : finalDate,
            saveDate: settings.processingMode == .locationOnly ? false : saveDateVal,
            removeDate: settings.processingMode == .locationOnly ? false : removeDateVal,
            place: settings.processingMode == .dateOnly ? nil : finalPlace,
            saveLocation: settings.processingMode == .dateOnly ? false : saveLocVal,
            removeLocation: settings.processingMode == .dateOnly ? false : removeLocVal,
            latitude: settings.processingMode == .dateOnly ? nil : finalLat,
            longitude: settings.processingMode == .dateOnly ? nil : finalLon,
            geocodedPlace: settings.processingMode == .dateOnly ? nil : finalGeo
        )
        manager.updateItemHint(id: item.id, hint: hintText)
    }
}

struct BatchEditPopover: View {
    let ids: Set<UUID>
    @ObservedObject var manager: PinmageManager
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) var dismiss

    // 0 = Do Not Change, 1 = Set/Save Date, 2 = Remove Date
    @State private var dateAction: Int = 0
    @State private var date: Date = Date()
    
    // 0 = Do Not Change, 1 = Set/Save Coords, 2 = Remove Location
    @State private var locationAction: Int = 0
    @State private var latitudeStr: String = ""
    @State private var longitudeStr: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Batch Edit (\(ids.count) items)")
                .font(.headline)
                .foregroundColor(.white)

            Divider().background(Color.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 12) {
                if settings.processingMode == .both || settings.processingMode == .dateOnly {
                    Text("Batch Date Action")
                        .font(.subheadline).fontWeight(.semibold)
                    Picker("", selection: $dateAction) {
                        Text("Do Not Change").tag(0)
                        Text("Set Date").tag(1)
                        Text("Remove Date").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    
                    if dateAction == 1 {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .padding(.top, 4)
                    }
                    
                    Divider().background(Color.white.opacity(0.05))
                }

                if settings.processingMode == .both || settings.processingMode == .locationOnly {
                    Text("Batch Location Action")
                        .font(.subheadline).fontWeight(.semibold)
                    Picker("", selection: $locationAction) {
                        Text("Do Not Change").tag(0)
                        Text("Set Coordinates").tag(1)
                        Text("Remove Location").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    
                    if locationAction == 1 {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Latitude").font(.caption).foregroundColor(.secondary)
                                TextField("Latitude", text: $latitudeStr)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: latitudeStr) { _, newValue in
                                        handleCoordinatePaste(newValue)
                                    }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Longitude").font(.caption).foregroundColor(.secondary)
                                TextField("Longitude", text: $longitudeStr)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: longitudeStr) { _, newValue in
                                        handleCoordinatePaste(newValue)
                                    }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(width: 260)

            Divider().background(Color.white.opacity(0.1))

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Apply") {
                    applyBatch()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func applyBatch() {
        let setDateVal = dateAction == 1
        let removeDateVal = dateAction == 2
        
        let setLocVal = locationAction == 1
        let removeLocVal = locationAction == 2
        
        let lat = setLocVal ? Double(latitudeStr) : nil
        let lon = setLocVal ? Double(longitudeStr) : nil
        
        manager.batchUpdateMetadata(
            ids: ids,
            date: settings.processingMode == .locationOnly ? nil : (setDateVal ? date : nil),
            saveDate: settings.processingMode == .locationOnly ? false : setDateVal,
            removeDate: settings.processingMode == .locationOnly ? false : removeDateVal,
            latitude: settings.processingMode == .dateOnly ? nil : lat,
            longitude: settings.processingMode == .dateOnly ? nil : lon,
            saveLocation: settings.processingMode == .dateOnly ? false : setLocVal,
            removeLocation: settings.processingMode == .dateOnly ? false : removeLocVal
        )
    }

    private func handleCoordinatePaste(_ input: String) {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.components(separatedBy: ",")
        if parts.count == 2 {
            let latVal = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let lonVal = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if Double(latVal) != nil && Double(lonVal) != nil {
                latitudeStr = latVal
                longitudeStr = lonVal
            }
        }
    }
}
struct ExplanationWhyButton: View {
    let title: String
    let explanation: String
    @State private var showingPopover = false
    
    var body: some View {
        Button(action: { showingPopover = true }) {
            Text("Why?")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.purple)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help("Show AI reasoning")
        .popover(isPresented: $showingPopover, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Divider().background(Color.white.opacity(0.1))
                
                Text(explanation)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 320)
            .padding(12)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct ImagePreviewPopover: View {
    let fileURL: URL
    @State private var image: NSImage? = nil
    @State private var zoomScale: CGFloat = 1.0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with filename and zoom controls
            HStack {
                Text(fileURL.lastPathComponent)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                Spacer()
                
                HStack(spacing: 8) {
                    Button(action: { withAnimation { zoomScale = max(0.25, zoomScale - 0.25) } }) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Zoom out")
                    
                    Text("\(Int(zoomScale * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .center)
                    
                    Button(action: { withAnimation { zoomScale = min(5.0, zoomScale + 0.25) } }) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Zoom in")
                    
                    Button(action: { withAnimation { zoomScale = 1.0 } }) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset zoom")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.95))
            
            Divider().background(Color.white.opacity(0.1))
            
            // Zoomable image area
            if let img = image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(zoomScale)
                        .frame(
                            width: min(img.size.width, 1200) * zoomScale,
                            height: min(img.size.height, 900) * zoomScale
                        )
                }
                .frame(
                    maxWidth: min(max(img.size.width * zoomScale, 400), 1200),
                    maxHeight: min(max(img.size.height * zoomScale, 300), 900)
                )
                .background(Color.black.opacity(0.85))
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading preview...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(width: 300, height: 300)
                .background(Color.black.opacity(0.85))
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            // Load large image asynchronously
            DispatchQueue.global(qos: .userInitiated).async {
                if let loadedImage = NSImage(contentsOf: fileURL) {
                    DispatchQueue.main.async {
                        self.image = loadedImage
                    }
                }
            }
        }
    }
}
