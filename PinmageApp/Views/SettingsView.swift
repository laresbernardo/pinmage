import SwiftUI
import AppKit
import MapKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var showResetConfirm = false
    @State private var showClearAllCacheConfirm = false
    @State private var showClearDateCacheConfirm = false
    @State private var showClearLocationCacheConfirm = false
    @State private var cacheEntryCount: Int = 0
    @State private var ollamaModels: [OllamaManager.OllamaModelInfo] = []
    @State private var ollamaRunning = false
    @State private var isRefreshingOllama = false
    @State private var newFavName = ""
    @State private var newFavLat = ""
    @State private var newFavLon = ""
    @State private var editingPlaceId: UUID? = nil
    @State private var editingName = ""
    @State private var editingLatitudeString = ""
    @State private var editingLongitudeString = ""
    @State private var mapSelectedPlaceId: UUID? = nil
    @State private var mapCenterCoordinate: CLLocationCoordinate2D? = nil
    @State private var mapCenterNeedUpdate = false
    @State private var showMapExplorer = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Section Title
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configuration Settings")
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Customize your Gemini integration, output directory, and AI prompts")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom, 8)
                
                // 1. AI Provider & Model Setup Card
                aiProviderCard
                
                // 2. Favourite Places Settings Card
                favouritePlacesCard
                
                // 3. File Destination Settings Card
                destinationSettingsCard
                
                // 4. Performance & Economy Settings Card
                performanceEconomyCard
                
                // 5. Processing Behaviour Card
                processingBehaviourCard
                
                // 6. AI Cost & Spend Tracker Card
                costSpendCard
            }
            .padding(24)
        }
        .confirmationDialog(
            "Reset Cumulative Spend?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Spend", role: .destructive) {
                settings.resetCumulativeSpend()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to reset the cumulative API spend history to $0.00? This action cannot be undone.")
        }
        .confirmationDialog(
            "Clear All Cache?",
            isPresented: $showClearAllCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All Cache", role: .destructive) {
                CacheManager.shared.clearCache()
                cacheEntryCount = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all cached AI analysis results (\(cacheEntryCount) entries). Future analysis will re-query the Gemini API for these images.")
        }
        .confirmationDialog(
            "Clear Date Cache?",
            isPresented: $showClearDateCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Date Cache", role: .destructive) {
                CacheManager.shared.clearDateCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the date fields from all cached entries. Location data will be preserved. Future analysis will re-detect dates for these images.")
        }
        .confirmationDialog(
            "Clear Location Cache?",
            isPresented: $showClearLocationCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Location Cache", role: .destructive) {
                CacheManager.shared.clearLocationCache()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the location fields from all cached entries. Date data will be preserved. Future analysis will re-detect locations for these images.")
        }
        .sheet(isPresented: $showMapExplorer) {
            FavouritePlacesMapExplorerView(
                settings: settings,
                selectedPlaceId: $mapSelectedPlaceId,
                mapCenterCoordinate: $mapCenterCoordinate,
                mapCenterNeedUpdate: $mapCenterNeedUpdate
            )
        }
    }
    
    // MARK: - Subcards
    
    @ViewBuilder
    private var aiProviderCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("AI Provider & Model Setup")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Provider")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    Picker("", selection: $settings.provider) {
                        ForEach(AIProvider.allCases, id: \.self) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 380)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                if settings.provider == .gemini {
                    geminiSection
                } else {
                    ollamaSection
                }
            }
            .padding(20)
        }
        .glassCardHoverEffect()
        .onChange(of: settings.provider) { _, newProvider in
            if newProvider == .ollama {
                Task { await refreshOllamaModels() }
            } else if newProvider == .gemini {
                settings.modelName = "gemini-3.1-flash-lite"
            }
        }
        .onAppear {
            if settings.provider == .ollama {
                Task { await refreshOllamaModels() }
            }
        }
    }
    
    @ViewBuilder
    private var favouritePlacesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundColor(.red)
                    Text("Favourite Places")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    if !settings.favoritePlaces.isEmpty {
                        Button(action: {
                            settings.favoritePlaces.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.caption)
                                Text("Sort A-Z")
                                    .font(.caption2)
                            }
                            .foregroundColor(.cyan)
                        }
                        .buttonStyle(.plain)
                        .help("Sort Alphabetically")
                    }
                }
                
                // Map Explorer Launcher
                HStack {
                    Spacer()
                    Button(action: {
                        showMapExplorer = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "map.fill")
                            Text("Open Map Explorer...")
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.cyan)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Open interactive map view to navigate and manage your favourite places")
                    Spacer()
                }
                .padding(.vertical, 8)
                
                Divider().background(Color.white.opacity(0.1))
                
                if settings.favoritePlaces.isEmpty {
                    Text("No favourite places saved yet. Add them here or pin them on the map.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(settings.favoritePlaces) { place in
                            if let idx = settings.favoritePlaces.firstIndex(where: { $0.id == place.id }) {
                                if editingPlaceId == place.id {
                                    // Edit Mode
                                    HStack(alignment: .center) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            TextField("Place Name", text: $editingName)
                                                .textFieldStyle(.roundedBorder)
                                                .font(.body)
                                                .foregroundColor(.white)
                                            
                                            HStack(spacing: 8) {
                                                TextField("Latitude", text: $editingLatitudeString)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.caption)
                                                    .frame(width: 100)
                                                
                                                TextField("Longitude", text: $editingLongitudeString)
                                                    .textFieldStyle(.roundedBorder)
                                                    .font(.caption)
                                                    .frame(width: 100)
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 12) {
                                            Button(action: {
                                                editingPlaceId = nil
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.secondary)
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Cancel")
                                            
                                            Button(action: {
                                                guard !editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                                guard let lat = Double(editingLatitudeString.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                      let lon = Double(editingLongitudeString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                                                
                                                settings.favoritePlaces[idx].name = editingName
                                                settings.favoritePlaces[idx].latitude = lat
                                                settings.favoritePlaces[idx].longitude = lon
                                                editingPlaceId = nil
                                            }) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(.green)
                                                    .font(.title3)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                                      Double(editingLatitudeString.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ||
                                                      Double(editingLongitudeString.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                                            .help("Save Changes")
                                        }
                                    }
                                    .padding(.vertical, 8)
                                } else {
                                    // View Mode
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(place.name)
                                                .font(.body)
                                                .fontWeight(.medium)
                                                .foregroundColor(.white)
                                            
                                            Text(String(format: "%.6f, %.6f", place.latitude, place.longitude))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        
                                        HStack(spacing: 16) {
                                            Button(action: {
                                                mapSelectedPlaceId = place.id
                                                mapCenterCoordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                                                mapCenterNeedUpdate = true
                                                showMapExplorer = true
                                            }) {
                                                Image(systemName: "mappin.circle.fill")
                                                    .foregroundColor(.cyan)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Show on Map")
                                            
                                            Button(action: {
                                                if idx > 0 {
                                                    settings.favoritePlaces.swapAt(idx, idx - 1)
                                                }
                                            }) {
                                                Image(systemName: "chevron.up")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(idx == 0)
                                            .help("Move Up")
                                            
                                            Button(action: {
                                                if idx < settings.favoritePlaces.count - 1 {
                                                    settings.favoritePlaces.swapAt(idx, idx + 1)
                                                }
                                            }) {
                                                Image(systemName: "chevron.down")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(idx == settings.favoritePlaces.count - 1)
                                            .help("Move Down")
                                            
                                            Button(action: {
                                                editingPlaceId = place.id
                                                editingName = place.name
                                                editingLatitudeString = String(format: "%.6f", place.latitude)
                                                editingLongitudeString = String(format: "%.6f", place.longitude)
                                            }) {
                                                Image(systemName: "pencil")
                                                    .foregroundColor(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Edit Place")
                                            
                                            Button(action: {
                                                settings.favoritePlaces.removeAll { $0.id == place.id }
                                                if mapSelectedPlaceId == place.id {
                                                    mapSelectedPlaceId = nil
                                                }
                                            }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Delete Place")
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                
                                if place != settings.favoritePlaces.last {
                                    Divider().background(Color.white.opacity(0.05))
                                }
                            }
                        }
                    }
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                // Add New Favourite Place directly
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add Favourite Place")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    HStack(spacing: 10) {
                        TextField("Place Name", text: $newFavName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Latitude", text: $newFavLat)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        
                        TextField("Longitude", text: $newFavLon)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        
                        Button(action: {
                            guard !newFavName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            guard let lat = Double(newFavLat.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  let lon = Double(newFavLon.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                            let newPlace = FavoritePlace(name: newFavName, latitude: lat, longitude: lon)
                            settings.favoritePlaces.append(newPlace)
                            newFavName = ""
                            newFavLat = ""
                            newFavLon = ""
                        }) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                                .foregroundColor(.cyan)
                        }
                        .buttonStyle(.plain)
                        .disabled(newFavName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  Double(newFavLat.trimmingCharacters(in: .whitespacesAndNewlines)) == nil || 
                                  Double(newFavLon.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                }
            }
            .padding(20)
        }
        .glassCardHoverEffect()
    }
    
    @ViewBuilder
    private var destinationSettingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("Destination Settings")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Output Folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    HStack {
                        TextField("Default (Save copy in original file folder)", text: $settings.outputFolderPath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        
                        Button("Choose Folder...") {
                            selectFolder()
                        }
                        .disabled(settings.overwriteOriginals)
                        
                        if !settings.outputFolderPath.isEmpty && !settings.overwriteOriginals {
                            Button(action: {
                                settings.outputFolderPath = ""
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    Text("Default leaves a copy with a suffix '_processed' in the source image location. If a different output folder is specified, files will be saved with their original names inside that folder.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .disabled(settings.overwriteOriginals)
                .opacity(settings.overwriteOriginals ? 0.5 : 1.0)
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Overwrite original files instead of creating copies", isOn: $settings.overwriteOriginals)
                        .toggleStyle(.checkbox)
                        .font(.body)
                        .foregroundColor(.white)
                    
                    if settings.overwriteOriginals {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.subheadline)
                            Text("WARNING: Overwriting original files replaces the source images on your disk. This action cannot be undone. Please ensure you have backups of your photos.")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.red)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 4)
                    }
                }
                
                if !settings.overwriteOriginals {
                    Divider().background(Color.white.opacity(0.1))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filename Renaming Format")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                        
                        Picker("", selection: $settings.filenamePattern) {
                            ForEach(FilenamePattern.allCases) { pattern in
                                Text(pattern.rawValue).tag(pattern)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320)
                        
                        Text("Automatically formats output copies to simplify sorting and chronological indexing (e.g. YYYYMMDD_ID_Location).")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .glassCardHoverEffect()
    }
    
    @ViewBuilder
    private var performanceEconomyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.medium")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("Performance & Economy")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Smart downscale of images (max 2048px width/height)", isOn: $settings.reduceImageSize)
                        .toggleStyle(.checkbox)
                        .font(.body)
                        .foregroundColor(.white)
                    
                    Text("Reduces upload bandwidth by up to 98% to maximize speed and prevent memory issues. Resized to high-quality JPEG.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Concurrent AI Requests:")
                            .foregroundColor(.white)
                        Text("\(settings.maxConcurrentRequests)")
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(settings.maxConcurrentRequests) },
                        set: { settings.maxConcurrentRequests = Int($0) }
                    ), in: 1...5, step: 1)
                    
                    Text("Controls the parallel request limits. Higher values analyze albums quicker but might trigger Gemini API rate limits (HTTP 429).")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local Metadata Cache Database")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    Text("Avoids paying for repetitive API calls of unmodified images by caching results.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("\(cacheEntryCount) cached entries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Clear Date Cache") {
                            showClearDateCacheConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cacheEntryCount == 0)
                        
                        Button("Clear Location Cache") {
                            showClearLocationCacheConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(cacheEntryCount == 0)
                        
                        Button("Clear All") {
                            showClearAllCacheConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .controlSize(.small)
                        .disabled(cacheEntryCount == 0)
                    }
                }
                .onAppear {
                    cacheEntryCount = CacheManager.shared.cacheCount
                }
            }
            .padding(20)
        }
        .glassCardHoverEffect()
    }
    
    @ViewBuilder
    private var processingBehaviourCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.day.timeline.leading")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("Processing Behaviour")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Extrapolate dates forward for unknown dates", isOn: $settings.extrapolateDates)
                        .toggleStyle(.checkbox)
                        .font(.body)
                        .foregroundColor(.white)
                    
                    Text("When enabled, images without a detected date will inherit the last known date from the previous image in the sorted list. You can re-apply this at any time from the Process view.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(20)
        }
        .glassCardHoverEffect()
    }
    
    @ViewBuilder
    private var costSpendCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "banknote.fill")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    Text("AI Cost & Spend Tracker")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Divider().background(Color.white.opacity(0.1))
                
                HStack(alignment: .center, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cumulative API Spend")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.semibold)
                        Text(formattedSpend(settings.cumulativeSpend))
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundColor(.cyan)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        showResetConfirm = true
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Reset Spend...")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                
                Text("Tracks real API cost calculated from Gemini's usageMetadata response. This is saved locally and can be reset at any time.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
        .glassCardHoverEffect()
    }
    
    // MARK: - Subviews & Helpers
    
    @ViewBuilder
    private var geminiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Gemini API Key")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.semibold)
            
            HStack {
                SecureField("AIzaSy...", text: $settings.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                
                Button(action: {
                    if let url = URL(string: "https://aistudio.google.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Get Key")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
            }
            Text("Your API key is saved locally in system UserDefaults.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        
        VStack(alignment: .leading, spacing: 6) {
            Text("Gemini Model")
                .font(.caption)
                .foregroundColor(.secondary)
                .fontWeight(.semibold)
            
            Picker("", selection: $settings.modelName) {
                Text("Gemini 3.1 Flash Lite (Recommended)").tag("gemini-3.1-flash-lite")
                Text("Gemini 3.5 Flash").tag("gemini-3.5-flash")
                Text("Gemini 2.5 Flash").tag("gemini-2.5-flash")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
        }
    }
    
    @ViewBuilder
    private var ollamaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(ollamaRunning ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(ollamaRunning ? "Ollama is running" : "Ollama is not running")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if !ollamaRunning {
                    Button("Retry") {
                        Task { await refreshOllamaModels() }
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                    .foregroundColor(.cyan)
                }
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ollama Model")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(action: {
                        Task { await refreshOllamaModels() }
                    }) {
                        HStack(spacing: 4) {
                            if isRefreshingOllama {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Refresh")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.cyan)
                    .disabled(isRefreshingOllama)
                }
                
                if ollamaModels.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text(ollamaRunning
                             ? "No models found. Install a multimodal model (e.g. llava) via Ollama first."
                             : "Start Ollama to see your installed models."
                        )
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    Picker("", selection: $settings.modelName) {
                        ForEach(ollamaModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 320)
                    
                    Text("Only multimodal models (e.g. llava, bakllava, moondream) support image analysis.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    private func refreshOllamaModels() async {
        isRefreshingOllama = true
        ollamaRunning = await OllamaManager.isRunning
        if ollamaRunning {
            do {
                let models = try await OllamaManager.fetchModels()
                ollamaModels = models
                if !models.contains(where: { $0.name == settings.modelName }) {
                    settings.modelName = models.first?.name ?? ""
                }
            } catch {
                ollamaModels = []
            }
        } else {
            ollamaModels = []
        }
        isRefreshingOllama = false
    }
    
    private func selectFolder() {
        let openPanel = NSOpenPanel()
        openPanel.title = "Select Output Folder"
        openPanel.showsHiddenFiles = false
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                settings.outputFolderPath = url.path
            }
        }
    }
    
    private func formattedSpend(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 5
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.5f", value)
    }
}
