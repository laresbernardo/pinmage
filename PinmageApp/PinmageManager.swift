import SwiftUI
import CoreLocation
import Combine
import MapKit

@MainActor class PinmageManager: ObservableObject {
    @Published var imageItems: [ImageItem] = []
    @Published var isProcessing = false
    @Published var currentProgress: Double = 0.0
    @Published var currentProcessingFile: String = ""
    
    @Published var totalProcessedCount = 0
    @Published var successfulCount = 0
    @Published var failedCount = 0
    @Published var sessionSpend: Double = 0.0
    @Published var batchDuration: TimeInterval? = nil
    
    private var cancellables = Set<AnyCancellable>()
    private var batchStartTime: Date? = nil
    
    // Supported extensions
    private let supportedExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif"]
    
    /// Adds image files to the processing queue and sorts them alphabetically by filename.
    func addImages(urls: [URL]) {
        var addedUrls: [URL] = []
        
        for url in urls {
            // Check if it is a directory
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // Recurse directory
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                                addedUrls.append(fileURL)
                            }
                        }
                    }
                } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                    addedUrls.append(url)
                }
            }
        }
        
        // Filter out duplicates
        let existingURLs = Set(imageItems.map { $0.fileURL })
        let uniqueNewUrls = addedUrls.filter { !existingURLs.contains($0) }
        
        var newItems = uniqueNewUrls.map { ImageItem(fileURL: $0) }
        
        // Check for existing GPS coordinates and compute cache hash for each new image
        for i in newItems.indices {
            if let coords = MetadataWriter.readExistingCoordinates(from: newItems[i].fileURL) {
                newItems[i].existingLatitude = coords.latitude
                newItems[i].existingLongitude = coords.longitude
            }
            newItems[i].cacheHash = CacheManager.computeHash(for: newItems[i].fileURL) ?? ""
        }
        
        // Reverse geocode existing coordinates for immediate place name display
        Task {
            for i in newItems.indices {
                guard let lat = newItems[i].existingLatitude, let lon = newItems[i].existingLongitude else { continue }
                if let geocoded = await GeocodingManager.reverseGeocode(latitude: lat, longitude: lon) {
                    if let index = self.imageItems.firstIndex(where: { $0.id == newItems[i].id }) {
                        self.imageItems[index].geocodedPlace = geocoded.resolvedName
                    }
                }
            }
        }
        
        // Sort items alphabetically by filename (essential for chronological matching of scanned album pages)
        newItems.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        
        // Combine and re-sort entire queue
        var allItems = imageItems + newItems
        allItems.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        
        self.imageItems = allItems
    }
    
    func removeImage(id: UUID) {
        self.imageItems.removeAll { $0.id == id }
    }
    
    func clearAll() {
        self.imageItems.removeAll()
        self.currentProgress = 0.0
        self.currentProcessingFile = ""
        self.totalProcessedCount = 0
        self.successfulCount = 0
        self.failedCount = 0
    }
    
    func stopProcessing() {
        self.isProcessing = false
    }
    
    func updateCheckboxes(threshold: Int) {
        for index in 0..<imageItems.count {
            let item = imageItems[index]
            if item.status == .analyzed {
                if let certainty = item.dateCertainty {
                    imageItems[index].saveDate = item.detectedDate != nil && certainty >= threshold
                }
                if let certainty = item.locationCertainty {
                    imageItems[index].saveLocation = item.latitude != nil && certainty >= threshold
                }
            }
        }
    }
    
    func toggleSaveDate(id: UUID) {
        if let index = imageItems.firstIndex(where: { $0.id == id }) {
            imageItems[index].saveDate.toggle()
            if imageItems[index].status == .completed {
                imageItems[index].status = .analyzed
            }
        }
    }
    
    func toggleSaveLocation(id: UUID) {
        if let index = imageItems.firstIndex(where: { $0.id == id }) {
            imageItems[index].saveLocation.toggle()
            if imageItems[index].status == .completed {
                imageItems[index].status = .analyzed
            }
        }
    }
    
    func updateItemHint(id: UUID, hint: String) {
        if let index = imageItems.firstIndex(where: { $0.id == id }) {
            imageItems[index].hint = hint
        }
    }
    
    func clearItemCache(id: UUID) {
        guard let index = imageItems.firstIndex(where: { $0.id == id }) else { return }
        CacheManager.shared.invalidateCache(hash: imageItems[index].cacheHash)
    }
    
    func updateItemMetadata(
        id: UUID,
        date: Date?,
        saveDate: Bool,
        removeDate: Bool,
        place: String?,
        saveLocation: Bool,
        removeLocation: Bool,
        latitude: Double?,
        longitude: Double?,
        geocodedPlace: String?
    ) {
        if let index = imageItems.firstIndex(where: { $0.id == id }) {
            imageItems[index].detectedDate = date
            imageItems[index].saveDate = saveDate && date != nil
            imageItems[index].removeDate = removeDate
            if let date = date {
                let formatter = DateFormatter()
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                imageItems[index].detectedDateString = formatter.string(from: date)
                imageItems[index].dateCertainty = 100
            } else {
                imageItems[index].detectedDateString = nil
                imageItems[index].dateCertainty = nil
            }
            imageItems[index].detectedPlace = place
            imageItems[index].saveLocation = saveLocation && latitude != nil && longitude != nil
            imageItems[index].removeLocation = removeLocation
            imageItems[index].latitude = latitude
            imageItems[index].longitude = longitude
            imageItems[index].geocodedPlace = geocodedPlace
            
            if imageItems[index].status == .pending || imageItems[index].status == .failed || imageItems[index].status == .completed {
                imageItems[index].status = .analyzed
            }
            
            // Invalidate cache since the user manually overwrote values
            CacheManager.shared.invalidateCache(hash: imageItems[index].cacheHash)
        }
    }
    
    func batchUpdateMetadata(ids: Set<UUID>, date: Date?, saveDate: Bool, removeDate: Bool, latitude: Double?, longitude: Double?, saveLocation: Bool, removeLocation: Bool) {
        for index in imageItems.indices {
            guard ids.contains(imageItems[index].id) else { continue }
            if removeDate {
                imageItems[index].detectedDate = nil
                imageItems[index].detectedDateString = nil
                imageItems[index].saveDate = false
                imageItems[index].removeDate = true
            } else if saveDate {
                imageItems[index].detectedDate = date
                imageItems[index].saveDate = date != nil
                imageItems[index].removeDate = false
                if let date = date {
                    let formatter = DateFormatter()
                    formatter.timeZone = TimeZone(secondsFromGMT: 0)
                    formatter.dateFormat = "yyyy-MM-dd"
                    imageItems[index].detectedDateString = formatter.string(from: date)
                    imageItems[index].dateCertainty = 100
                } else {
                    imageItems[index].detectedDateString = nil
                    imageItems[index].dateCertainty = nil
                }
            }
            if removeLocation {
                imageItems[index].latitude = nil
                imageItems[index].longitude = nil
                imageItems[index].saveLocation = false
                imageItems[index].removeLocation = true
            } else if saveLocation {
                imageItems[index].latitude = latitude
                imageItems[index].longitude = longitude
                imageItems[index].saveLocation = latitude != nil && longitude != nil
                imageItems[index].removeLocation = false
            }
            if imageItems[index].status == .pending || imageItems[index].status == .failed || imageItems[index].status == .completed {
                imageItems[index].status = .analyzed
            }
            CacheManager.shared.invalidateCache(hash: imageItems[index].cacheHash)
        }
    }
    
    private struct AnalysisUpdate {
        let index: Int
        let success: Bool
        let result: GeminiManager.GeminiResult?
        let errorDescription: String?
        let latitude: Double?
        let longitude: Double?
        let geocodedPlace: String?
        let processingDuration: TimeInterval?
    }
    
    func updateItemStatus(index: Int, status: ProcessStatus, fileName: String? = nil, place: String? = nil) {
        if let fileName = fileName {
            self.currentProcessingFile = fileName
        }
        if index < self.imageItems.count {
            self.imageItems[index].status = status
            if let place = place {
                self.imageItems[index].detectedPlace = place
            }
        }
    }
    
    func updateSpend(settings: AppSettings, cost: Double) {
        settings.cumulativeSpend += cost
        self.sessionSpend += cost
    }
    
    /// Phase 1: Calls AI to analyze dates, locations, coordinates, and certainty scores in parallel with concurrency limits.
    func startAnalysis(settings: AppSettings) async {
        guard !isProcessing else { return }
        
        // Check API key (Gemini only)
        if settings.provider == .gemini && settings.apiKey.isEmpty {
            for i in 0..<self.imageItems.count {
                if self.imageItems[i].status == .pending {
                    self.imageItems[i].status = .failed
                    self.imageItems[i].errorMessage = "API Key is missing. Please set it in Settings."
                }
            }
            return
        }
        
        self.isProcessing = true
        self.totalProcessedCount = 0
        self.successfulCount = 0
        self.failedCount = 0
        self.sessionSpend = 0.0
        self.currentProgress = 0.0
        self.batchDuration = nil
        self.batchStartTime = Date()
        
        let indicesToProcess = imageItems.indices.filter {
            let item = imageItems[$0]
            return item.status != .analyzed && item.status != .completed
        }
        
        if indicesToProcess.isEmpty {
            self.isProcessing = false
            self.currentProgress = 1.0
            self.currentProcessingFile = "Done"
            return
        }
        
        let provider = settings.provider
        let apiKey = settings.apiKey
        let modelName = settings.modelName
        let customPrompt = settings.customPrompt
        let reduceImageSize = settings.reduceImageSize
        let maxConcurrentRequests = settings.maxConcurrentRequests
        let locationHint = settings.locationHint
        let processingMode = settings.processingMode
        
        // Concurrency-limited processing loop
        await withTaskGroup(of: AnalysisUpdate.self) { group in
            var activeIndex = 0
            let limit = maxConcurrentRequests
            
            // Spawn initial batch up to concurrency limit
            while activeIndex < limit && activeIndex < indicesToProcess.count {
                let idx = indicesToProcess[activeIndex]
                activeIndex += 1
                let item = imageItems[idx]
                let skipCoords = settings.skipExistingCoordinates
                group.addTask {
                    await self.analyzeSingleItem(
                        index: idx,
                        itemURL: item.fileURL,
                        fileName: item.fileName,
                        provider: provider,
                        apiKey: apiKey,
                        modelName: modelName,
                        customPrompt: customPrompt,
                        reduceImageSize: reduceImageSize,
                        skipExistingCoordinates: skipCoords,
                        existingLatitude: item.existingLatitude,
                        existingLongitude: item.existingLongitude,
                        locationHint: locationHint,
                        imageHint: item.hint,
                        processingMode: processingMode,
                        manager: self,
                        settings: settings
                    )
                }
            }
            
            // Collect updates and spawn new ones
            var completedCount = 0
            while let update = await group.next() {
                completedCount += 1
                
                self.applyUpdate(update, processingMode: settings.processingMode, certaintyThreshold: settings.certaintyThreshold)
                self.currentProgress = Double(completedCount) / Double(indicesToProcess.count)
                
                // If cancelled, stop spawning new tasks
                if !self.isProcessing {
                    break
                }
                
                if activeIndex < indicesToProcess.count {
                    let idx = indicesToProcess[activeIndex]
                    activeIndex += 1
                    let item = imageItems[idx]
                    let skipCoords = settings.skipExistingCoordinates
                    group.addTask {
                        await self.analyzeSingleItem(
                            index: idx,
                            itemURL: item.fileURL,
                            fileName: item.fileName,
                            provider: provider,
                            apiKey: apiKey,
                            modelName: modelName,
                            customPrompt: customPrompt,
                            reduceImageSize: reduceImageSize,
                            skipExistingCoordinates: skipCoords,
                            existingLatitude: item.existingLatitude,
                            existingLongitude: item.existingLongitude,
                            locationHint: locationHint,
                            imageHint: item.hint,
                            processingMode: processingMode,
                            manager: self,
                            settings: settings
                        )
                    }
                }
            }
        }
        
        // Phase 1b: Chronological date extrapolation (off by default)
        if settings.extrapolateDates {
            applyDateExtrapolation(threshold: settings.certaintyThreshold)
        }
        
        if let start = self.batchStartTime {
            self.batchDuration = Date().timeIntervalSince(start)
        }
        self.isProcessing = false
        self.currentProgress = 1.0
        self.currentProcessingFile = "Done"
    }
    
    /// Reprocesses a single item directly, clearing its cache first.
    func reprocessSingleItem(id: UUID, settings: AppSettings) async {
        guard let index = imageItems.firstIndex(where: { $0.id == id }) else { return }
        guard !isProcessing else { return }
        
        isProcessing = true
        self.sessionSpend = 0.0
        
        let item = imageItems[index]
        
        // 1. Invalidate local cache for this item to force AI run
        CacheManager.shared.invalidateCache(hash: item.cacheHash)
        
        // 2. Setup configuration parameters
        let provider = settings.provider
        let apiKey = settings.apiKey
        let modelName = settings.modelName
        let customPrompt = settings.customPrompt
        let reduceImageSize = settings.reduceImageSize
        let locationHint = settings.locationHint
        let processingMode = settings.processingMode
        let skipCoords = settings.skipExistingCoordinates
        
        // 3. Analyze item
        let update = await analyzeSingleItem(
            index: index,
            itemURL: item.fileURL,
            fileName: item.fileName,
            provider: provider,
            apiKey: apiKey,
            modelName: modelName,
            customPrompt: customPrompt,
            reduceImageSize: reduceImageSize,
            skipExistingCoordinates: skipCoords,
            existingLatitude: item.existingLatitude,
            existingLongitude: item.existingLongitude,
            locationHint: locationHint,
            imageHint: item.hint,
            processingMode: processingMode,
            manager: self,
            settings: settings
        )
        
        // 4. Apply update
        self.applyUpdate(update, processingMode: processingMode, certaintyThreshold: settings.certaintyThreshold)
        
        self.isProcessing = false
        self.currentProcessingFile = "Done"
    }
    
    /// Chronological date extrapolation: forward-fills dates from analyzed items to items with unknown dates.
    /// Can be called independently after analysis to apply or re-apply date inheritance.
    func applyDateExtrapolation(threshold: Int? = nil) {
        var lastKnownDate: Date? = nil
        var lastKnownCertainty: Int? = nil
        
        for item in self.imageItems {
            if (item.status == .analyzed || item.status == .completed) && !item.dateIsInherited {
                if let date = item.detectedDate {
                    lastKnownDate = date
                    lastKnownCertainty = item.dateCertainty
                }
            }
        }
        
        for index in 0..<self.imageItems.count {
            let item = self.imageItems[index]
            if item.status == .analyzed || item.status == .completed {
                if let date = item.detectedDate, !item.dateIsInherited {
                    lastKnownDate = date
                    lastKnownCertainty = item.dateCertainty
                } else if item.detectedDate == nil || item.dateIsInherited {
                    if let previousDate = lastKnownDate {
                        self.imageItems[index].detectedDate = previousDate
                        self.imageItems[index].dateCertainty = lastKnownCertainty
                        self.imageItems[index].dateIsInherited = true
                        
                        if let certainty = lastKnownCertainty, let threshold = threshold {
                            self.imageItems[index].saveDate = certainty >= threshold
                        }
                    }
                }
            }
        }
    }
    
    private nonisolated func analyzeSingleItem(
        index: Int,
        itemURL: URL,
        fileName: String,
        provider: AIProvider,
        apiKey: String,
        modelName: String,
        customPrompt: String,
        reduceImageSize: Bool,
        skipExistingCoordinates: Bool,
        existingLatitude: Double?,
        existingLongitude: Double?,
        locationHint: String,
        imageHint: String,
        processingMode: ProcessingMode,
        manager: PinmageManager,
        settings: AppSettings
    ) async -> AnalysisUpdate {
        await manager.updateItemStatus(index: index, status: .processing, fileName: fileName)
        let itemStartTime = Date()
        
        let hasExistingCoords = skipExistingCoordinates && existingLatitude != nil && existingLongitude != nil
        
        // 1. Compute image hash for local cache
        let hash = CacheManager.computeHash(for: itemURL) ?? ""
        var geminiResult: GeminiManager.GeminiResult? = nil
        var errorDescription: String? = nil
        
        // 2. Query Cache
        if !hash.isEmpty, let cachedResult = CacheManager.shared.get(hash: hash) {
            let hasRequiredDate = (processingMode == .both || processingMode == .dateOnly) ? (cachedResult.dateAnalyzed ?? true) : true
            let hasRequiredLocation = (processingMode == .both || processingMode == .locationOnly) ? (cachedResult.locationAnalyzed ?? true) : true
            
            if hasRequiredDate && hasRequiredLocation {
                geminiResult = cachedResult
            }
        }
        
        if geminiResult == nil {
            // Cache miss - Analyze with AI
            await manager.updateItemStatus(index: index, status: .callingAPI)
            
            // Retry with exponential backoff
            var attempts = 0
            let maxAttempts = 5
            var delayNanoseconds: UInt64 = 3_000_000_000 // 3 seconds
            
            while attempts < maxAttempts {
                let stillProcessing = await manager.isProcessing
                if !stillProcessing { break }
                do {
                    var contextualPrompt = "\(customPrompt)\n\nThe image file is named \"\(fileName)\". The filename may contain date or location hints — use it as additional context if relevant."
                    if !locationHint.isEmpty {
                        contextualPrompt += "\n\nThe user provided the following context about this batch of images: \"\(locationHint)\". Use it as helpful context for identifying dates and locations with more confidence, but only where it aligns with the visual evidence in each image."
                    }
                    if !imageHint.isEmpty {
                        contextualPrompt += "\n\nThe user provided a hint specific to this image: \"\(imageHint)\". Use this as a strong signal for identifying the date and location."
                    }
                    contextualPrompt += "\n\nIMPORTANT: When identifying the place/location, use a well-known canonical name (e.g., \"Eiffel Tower, Paris, France\" rather than \"that tower in Paris\" or vague descriptions). This ensures the location can be accurately geocoded to coordinates."
                    contextualPrompt += "\n\nCRITICAL — dateCertainty and locationCertainty MUST be integers between 0 and 100 only. Values like 95, 80, 50 are valid. A value of 500, 1000, or 0.95 is INVALID and will be rejected."
                    let response: OllamaManager.AnalysisResponse
                    if provider == .ollama {
                        let ollamaResponse = try await OllamaManager.analyzeImage(
                            fileURL: itemURL,
                            modelName: modelName,
                            prompt: contextualPrompt,
                            processingMode: processingMode,
                            reduceSize: reduceImageSize
                        )
                        response = ollamaResponse
                    } else {
                        let geminiResponse = try await GeminiManager.analyzeImage(
                            fileURL: itemURL,
                            apiKey: apiKey,
                            modelName: modelName,
                            prompt: contextualPrompt,
                            processingMode: processingMode,
                            reduceSize: reduceImageSize
                        )
                        response = OllamaManager.AnalysisResponse(
                            result: geminiResponse.result,
                            inputTokens: geminiResponse.inputTokens,
                            outputTokens: geminiResponse.outputTokens
                        )
                    }
                    geminiResult = response.result
                    
                    let cost = Self.calculateCost(inputTokens: response.inputTokens, outputTokens: response.outputTokens, model: modelName, provider: provider)
                    await manager.updateSpend(settings: settings, cost: cost)
                    break // success
                } catch {
                    attempts += 1
                    let nsError = error as NSError
                    let is503 = nsError.domain == "GeminiManager" && nsError.code == 503
                    if is503 {
                        delayNanoseconds = min(delayNanoseconds * 2, 60_000_000_000) // cap at 60s
                    } else {
                        delayNanoseconds *= 2
                    }
                    errorDescription = error.localizedDescription
                    print("Attempt \(attempts) failed for \(fileName): \(error.localizedDescription)")
                    let processing = await manager.isProcessing
                    if attempts < maxAttempts && processing {
                        if is503 && attempts >= 3 {
                            await manager.updateItemStatus(index: index, status: .callingAPI, fileName: "\(fileName) (retry \(attempts+1)/\(maxAttempts))")
                        }
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                    }
                }
            }
            
            // Save to local cache on success
            if let result = geminiResult, !hash.isEmpty {
                var cachedResult = result
                cachedResult.dateAnalyzed = (processingMode == .both || processingMode == .dateOnly)
                cachedResult.locationAnalyzed = (processingMode == .both || processingMode == .locationOnly)
                CacheManager.shared.set(hash: hash, result: cachedResult)
            }
        }
        
        guard let result = geminiResult else {
            return AnalysisUpdate(
                index: index,
                success: false,
                result: nil,
                errorDescription: errorDescription ?? "AI analysis failed",
                latitude: nil,
                longitude: nil,
                geocodedPlace: nil,
                processingDuration: Date().timeIntervalSince(itemStartTime)
            )
        }
        
        // 3. Geocode place name to coordinates (AI is only used for place name extraction, not coordinates)
        var latitude: Double? = nil
        var longitude: Double? = nil
        var geocodedPlace: String? = nil
        
        // If image already has GPS coordinates and skip is on, use existing instead of AI result
        if processingMode == .both || processingMode == .locationOnly {
            if hasExistingCoords {
                latitude = existingLatitude
                longitude = existingLongitude
                if let geocoded = await GeocodingManager.reverseGeocode(latitude: existingLatitude!, longitude: existingLongitude!) {
                    geocodedPlace = geocoded.resolvedName
                }
            } else if let place = result.place, !place.isEmpty, place.lowercased() != "null" {
                await manager.updateItemStatus(index: index, status: .geocoding, place: place)
                if let geocoded = await GeocodingManager.geocode(address: place) {
                    latitude = geocoded.coordinate.latitude
                    longitude = geocoded.coordinate.longitude
                    geocodedPlace = geocoded.resolvedName
                }
            }
        }
        
        return AnalysisUpdate(
            index: index,
            success: true,
            result: result,
            errorDescription: nil,
            latitude: latitude,
            longitude: longitude,
            geocodedPlace: geocodedPlace,
            processingDuration: Date().timeIntervalSince(itemStartTime)
        )
    }
    
    private func applyUpdate(_ update: AnalysisUpdate, processingMode: ProcessingMode, certaintyThreshold: Int) {
        let index = update.index
        guard index < self.imageItems.count else { return }
        
        if update.success, let result = update.result {
            var parsedDate: Date? = nil
            var dateCertainty = min(max(result.dateCertainty ?? 0, 0), 100)
            var finalDateStr = result.date
            
            if let dateStr = result.date, !dateStr.isEmpty, dateStr.lowercased() != "null" {
                if let parseResult = parseDateAndCheckPartial(from: dateStr) {
                    parsedDate = parseResult.date
                    if parseResult.isPartial {
                        // Cap certainty to 75% for partial dates (guessed days/months)
                        dateCertainty = min(dateCertainty, 75)
                        
                        // Format back to YYYY-MM-DD
                        let outFormatter = DateFormatter()
                        outFormatter.timeZone = TimeZone(secondsFromGMT: 0)
                        outFormatter.dateFormat = "yyyy-MM-dd"
                        finalDateStr = outFormatter.string(from: parseResult.date)
                    }
                }
            }
            
            let locationCertainty = min(max(result.locationCertainty ?? 0, 0), 100)
            
            if processingMode == .both || processingMode == .dateOnly {
                self.imageItems[index].detectedDate = parsedDate
                self.imageItems[index].detectedDateString = finalDateStr
                self.imageItems[index].dateCertainty = dateCertainty
                self.imageItems[index].saveDate = parsedDate != nil && dateCertainty >= certaintyThreshold
                self.imageItems[index].removeDate = false
            } else {
                self.imageItems[index].detectedDate = nil
                self.imageItems[index].detectedDateString = nil
                self.imageItems[index].dateCertainty = nil
                self.imageItems[index].saveDate = false
                self.imageItems[index].removeDate = false
            }
            
            if processingMode == .both || processingMode == .locationOnly {
                self.imageItems[index].detectedPlace = result.place
                self.imageItems[index].locationCertainty = locationCertainty
                self.imageItems[index].latitude = update.latitude
                self.imageItems[index].longitude = update.longitude
                self.imageItems[index].geocodedPlace = update.geocodedPlace
                self.imageItems[index].removeLocation = false
                
                let item = self.imageItems[index]
                let usingExistingCoords = update.latitude != nil && item.existingLatitude != nil &&
                    abs(update.latitude! - item.existingLatitude!) < 0.0001 &&
                    abs(update.longitude! - item.existingLongitude!) < 0.0001
                if usingExistingCoords {
                    self.imageItems[index].saveLocation = true
                } else {
                    self.imageItems[index].saveLocation = update.latitude != nil && locationCertainty >= certaintyThreshold
                }
            } else {
                self.imageItems[index].detectedPlace = nil
                self.imageItems[index].locationCertainty = nil
                self.imageItems[index].latitude = nil
                self.imageItems[index].longitude = nil
                self.imageItems[index].geocodedPlace = nil
                self.imageItems[index].saveLocation = false
                self.imageItems[index].removeLocation = false
            }
            
            self.imageItems[index].dateIsInherited = false
            self.imageItems[index].processingDuration = update.processingDuration
            self.imageItems[index].status = .analyzed
            self.successfulCount += 1
        } else {
            self.imageItems[index].processingDuration = update.processingDuration
            self.imageItems[index].status = .failed
            self.imageItems[index].errorMessage = update.errorDescription
            self.failedCount += 1
        }
        self.totalProcessedCount += 1
    }
    
    /// Phase 2: Writes metadata to files for items that are analyzed, based on the certainty threshold.
    func startWriting(settings: AppSettings) async {
        guard !isProcessing else { return }
        
        self.isProcessing = true
        self.totalProcessedCount = 0
        self.successfulCount = 0
        self.failedCount = 0
        self.currentProgress = 0.0
        
        let itemsToProcessIndices = imageItems.indices.filter { imageItems[$0].status == .analyzed }
        
        let overwriteOriginals = settings.overwriteOriginals
        let outputFolderPath = settings.outputFolderPath
        let filenamePattern = settings.filenamePattern
        
        for (processCount, index) in itemsToProcessIndices.enumerated() {
            // Check if processing was cancelled
            if !isProcessing { break }
            
            let item = imageItems[index]
            
            self.currentProcessingFile = item.fileName
            self.imageItems[index].status = .writing
            self.currentProgress = Double(processCount) / Double(itemsToProcessIndices.count)
            
            let result = await writeSingleItem(
                item: item,
                overwriteOriginals: overwriteOriginals,
                outputFolderPath: outputFolderPath,
                filenamePattern: filenamePattern,
                processingMode: settings.processingMode
            )
            
            switch result {
            case .success(let outputURL):
                self.imageItems[index].status = .completed
                self.imageItems[index].outputURL = outputURL
                self.successfulCount += 1
            case .failure(let error):
                print("Error writing file \(item.fileName): \(error)")
                self.imageItems[index].status = .failed
                self.imageItems[index].errorMessage = error.localizedDescription
                self.failedCount += 1
            }
            self.totalProcessedCount += 1
        }
        
        self.isProcessing = false
        self.currentProgress = 1.0
        self.currentProcessingFile = "Done"
    }
    
    private nonisolated func writeSingleItem(
        item: ImageItem,
        overwriteOriginals: Bool,
        outputFolderPath: String,
        filenamePattern: FilenamePattern,
        processingMode: ProcessingMode
    ) async -> Result<URL, Error> {
        do {
            // Determine if we apply date and/or location based on checkboxes
            let dateValid = (processingMode == .both || processingMode == .dateOnly) && item.saveDate && item.detectedDate != nil
            let locationValid = (processingMode == .both || processingMode == .locationOnly) && item.saveLocation && item.latitude != nil && item.longitude != nil
            
            let parsedDate = dateValid ? item.detectedDate : nil
            let latitude = locationValid ? item.latitude : nil
            let longitude = locationValid ? item.longitude : nil
            let placeForFilename = locationValid ? item.detectedPlace : nil
            
            let outputURL: URL
            if overwriteOriginals {
                outputURL = item.fileURL
            } else {
                let outputFolderURL: URL
                if !outputFolderPath.isEmpty {
                    outputFolderURL = URL(fileURLWithPath: outputFolderPath)
                } else {
                    // Default is same directory as the original file
                    outputFolderURL = item.fileURL.deletingLastPathComponent()
                }
                
                // Create output folder if it doesn't exist
                try FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true, attributes: nil)
                
                var resolvedName = resolveOutputFilename(
                    fileURL: item.fileURL,
                    date: parsedDate,
                    place: placeForFilename,
                    pattern: filenamePattern
                )
                
                // Prevent accidental overwriting of the source file
                if outputFolderURL.path == item.fileURL.deletingLastPathComponent().path && resolvedName == item.fileName {
                    let baseName = item.fileURL.deletingPathExtension().lastPathComponent
                    let ext = item.fileURL.pathExtension
                    resolvedName = "\(baseName)_processed.\(ext)"
                }
                
                outputURL = outputFolderURL.appendingPathComponent(resolvedName)
            }
            
            // Write EXIF tags / GPS tags or strip them based on configuration
            let removeDateTag = (processingMode == .both || processingMode == .dateOnly) && item.removeDate
            let removeLocationTag = (processingMode == .both || processingMode == .locationOnly) && item.removeLocation
            
            // Write Metadata to copy file
            let success = MetadataWriter.updateImageMetadata(
                sourceURL: item.fileURL,
                destinationURL: outputURL,
                date: parsedDate,
                removeDate: removeDateTag,
                latitude: latitude,
                longitude: longitude,
                removeLocation: removeLocationTag
            )
            
            if success {
                return .success(outputURL)
            } else {
                return .failure(NSError(domain: "PinmageManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to compile/save final image metadata"]))
            }
        } catch {
            return .failure(error)
        }
    }
    
    struct DateParseResult {
        let date: Date
        let isPartial: Bool
    }
    
    private func parseDateAndCheckPartial(from string: String) -> DateParseResult? {
        let cleanStr = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        // Try YYYY-MM-DD
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: cleanStr) {
            return DateParseResult(date: date, isPartial: false)
        }
        
        // Try YYYY-MM
        formatter.dateFormat = "yyyy-MM"
        if let date = formatter.date(from: cleanStr) {
            return DateParseResult(date: date, isPartial: true)
        }
        
        // Try YYYY
        formatter.dateFormat = "yyyy"
        if let date = formatter.date(from: cleanStr) {
            return DateParseResult(date: date, isPartial: true)
        }
        
        return nil
    }
    
    private func parseDate(from string: String) -> Date? {
        return parseDateAndCheckPartial(from: string)?.date
    }
    
    private nonisolated func resolveOutputFilename(fileURL: URL, date: Date?, place: String?, pattern: FilenamePattern) -> String {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        
        var dateStr = ""
        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            dateStr = formatter.string(from: date)
        }
        
        var placeStr = ""
        if let place = place, !place.isEmpty, place.lowercased() != "null" {
            placeStr = place
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: "-")
        }
        
        switch pattern {
        case .original:
            return fileURL.lastPathComponent
        case .dateAndName:
            if !dateStr.isEmpty {
                return "\(dateStr)_\(baseName).\(ext)"
            }
            return fileURL.lastPathComponent
        case .fullArchive:
            if !dateStr.isEmpty && !placeStr.isEmpty {
                return "\(dateStr)_\(baseName)_\(placeStr).\(ext)"
            } else if !dateStr.isEmpty {
                return "\(dateStr)_\(baseName).\(ext)"
            } else if !placeStr.isEmpty {
                return "\(baseName)_\(placeStr).\(ext)"
            }
            return fileURL.lastPathComponent
        }
    }
    
    private nonisolated static func calculateCost(inputTokens: Int, outputTokens: Int, model: String, provider: AIProvider = .gemini) -> Double {
        if provider == .ollama {
            return 0.0
        }
        let isPro = model.contains("pro")
        let inputRate = isPro ? 1.25 : 0.075
        let outputRate = isPro ? 5.00 : 0.30
        
        return (Double(inputTokens) * inputRate / 1_000_000.0) + (Double(outputTokens) * outputRate / 1_000_000.0)
    }
}

class GeocodingManager {
    private static var forwardCache: [String: GeocodedLocation] = [:]
    private static var reverseCache: [String: GeocodedLocation] = [:]
    private static let rateLimiter = GeocodingRateLimiter()

    struct GeocodedLocation {
        let coordinate: CLLocationCoordinate2D
        let resolvedName: String?
    }

    static func clearCache() {
        forwardCache.removeAll()
        reverseCache.removeAll()
    }

    private static func normalizeKey(_ text: String) -> String {
        let cleaned = text
            .lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters).joined()
            .components(separatedBy: CharacterSet.symbols).joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fillerWords: Set<String> = ["the", "a", "an", "of", "in", "at", "on", "for", "to", "and", "or", "is", "it", "its", "with", "by", "from", "as", "be", "was"]
        return cleaned
            .components(separatedBy: " ")
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .joined(separator: " ")
    }

    private static func isValidCoordinate(_ latitude: Double, _ longitude: Double) -> Bool {
        guard latitude != 0 || longitude != 0 else { return false }
        guard latitude.isFinite, longitude.isFinite else { return false }
        guard latitude >= -90 && latitude <= 90 else { return false }
        guard longitude >= -180 && longitude <= 180 else { return false }
        return true
    }

    static func geocode(address: String) async -> GeocodedLocation? {
        let key = normalizeKey(address)
        if key.isEmpty { return nil }
        if let cached = forwardCache[key] {
            return cached
        }

        if let result = await performGeocode(address: address) {
            forwardCache[key] = result
            return result
        }

        // Fallback: If geocoding failed for the full address (which often happens with specific tourist sights/monuments),
        // try geocoding the parent location by dropping the first part of a comma-separated address.
        let parts = address.components(separatedBy: ",")
        if parts.count > 1 {
            let fallbackAddress = parts.dropFirst().joined(separator: ",").trimmingCharacters(in: .whitespacesAndNewlines)
            print("Geocoding failed for '\(address)'. Trying fallback: '\(fallbackAddress)'")
            if let result = await geocode(address: fallbackAddress) {
                // Cache the resolved fallback location for the original query key to avoid repeating
                forwardCache[key] = result
                return result
            }
        }

        return nil
    }

    private static func performGeocode(address: String) async -> GeocodedLocation? {
        for attempt in 1...3 {
            await rateLimiter.throttle()

            do {
                let result: GeocodedLocation
                if #available(macOS 26, *) {
                    guard let request = MKGeocodingRequest(addressString: address) else { return nil }
                    let mapItems = try await request.mapItems
                    guard let mapItem = mapItems.first else { return nil }
                    let resolved = [mapItem.name, mapItem.address?.shortAddress]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    result = GeocodedLocation(
                        coordinate: mapItem.location.coordinate,
                        resolvedName: resolved.isEmpty ? nil : resolved
                    )
                } else {
                    let geocoder = CLGeocoder()
                    let placemarks = try await geocoder.geocodeAddressString(address)
                    guard let placemark = placemarks.first else { return nil }
                    let resolved = [placemark.name, placemark.locality, placemark.administrativeArea, placemark.country]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    result = GeocodedLocation(
                        coordinate: placemark.location?.coordinate ?? CLLocationCoordinate2D(),
                        resolvedName: resolved.isEmpty ? nil : resolved
                    )
                }

                guard isValidCoordinate(result.coordinate.latitude, result.coordinate.longitude) else {
                    print("Geocoding discarded invalid coordinates for '\(address)': (\(result.coordinate.latitude), \(result.coordinate.longitude))")
                    return nil
                }

                await rateLimiter.recordSuccess()
                return result
            } catch {
                print("Geocoding error for '\(address)' (attempt \(attempt)): \(error.localizedDescription)")
                await rateLimiter.recordError()
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: await rateLimiter.backoffDelay)
                }
            }
        }
        return nil
    }

    static func reverseGeocode(latitude: Double, longitude: Double) async -> GeocodedLocation? {
        guard isValidCoordinate(latitude, longitude) else { return nil }

        let key = String(format: "%.4f,%.4f", latitude, longitude)
        if let cached = reverseCache[key] {
            return cached
        }

        for attempt in 1...3 {
            await rateLimiter.throttle()

            do {
                let result: GeocodedLocation
                let location = CLLocation(latitude: latitude, longitude: longitude)
                if #available(macOS 26, *) {
                    guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
                    let mapItems = try await request.mapItems
                    guard let mapItem = mapItems.first else { return nil }
                    let resolved = [mapItem.name, mapItem.address?.shortAddress]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    result = GeocodedLocation(
                        coordinate: mapItem.location.coordinate,
                        resolvedName: resolved.isEmpty ? nil : resolved
                    )
                } else {
                    let geocoder = CLGeocoder()
                    let placemarks = try await geocoder.reverseGeocodeLocation(location)
                    guard let placemark = placemarks.first else { return nil }
                    let resolved = [placemark.name, placemark.locality, placemark.administrativeArea, placemark.country]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: ", ")
                    result = GeocodedLocation(
                        coordinate: placemark.location?.coordinate ?? location.coordinate,
                        resolvedName: resolved.isEmpty ? nil : resolved
                    )
                }

                reverseCache[key] = result
                await rateLimiter.recordSuccess()
                return result
            } catch {
                print("Reverse geocoding error (\(attempt)): \(error.localizedDescription)")
                await rateLimiter.recordError()
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: await rateLimiter.backoffDelay)
                }
            }
        }
        return nil
    }
}

private actor GeocodingRateLimiter {
    private var lastRequest: Date = .distantPast
    private var errorCount = 0
    let minimumInterval: TimeInterval = 0.3

    func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < minimumInterval {
            try? await Task.sleep(nanoseconds: UInt64((minimumInterval - elapsed) * 1_000_000_000))
        }
        lastRequest = Date()
    }

    var backoffDelay: UInt64 {
        guard errorCount > 0 else { return 0 }
        let seconds = min(pow(2.0, Double(errorCount)), 30.0)
        return UInt64(seconds * 1_000_000_000)
    }

    func recordSuccess() {
        errorCount = 0
    }

    func recordError() {
        errorCount += 1
    }
}
