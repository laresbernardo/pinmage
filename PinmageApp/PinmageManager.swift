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
    
    private var cancellables = Set<AnyCancellable>()
    
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
    
    func updateItemMetadata(
        id: UUID,
        date: Date?,
        saveDate: Bool,
        place: String?,
        saveLocation: Bool,
        latitude: Double?,
        longitude: Double?,
        geocodedPlace: String?
    ) {
        if let index = imageItems.firstIndex(where: { $0.id == id }) {
            imageItems[index].detectedDate = date
            imageItems[index].saveDate = saveDate && date != nil
            imageItems[index].detectedPlace = place
            imageItems[index].saveLocation = saveLocation && latitude != nil && longitude != nil
            imageItems[index].latitude = latitude
            imageItems[index].longitude = longitude
            imageItems[index].geocodedPlace = geocodedPlace
            
            if imageItems[index].status == .pending || imageItems[index].status == .failed || imageItems[index].status == .completed {
                imageItems[index].status = .analyzed
            }
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
    }
    
    /// Phase 1: Calls AI to analyze dates, locations, coordinates, and certainty scores in parallel with concurrency limits.
    func startAnalysis(settings: AppSettings) async {
        guard !isProcessing else { return }
        
        // Check API key
        if settings.apiKey.isEmpty {
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
        self.currentProgress = 0.0
        
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
        
        let apiKey = settings.apiKey
        let modelName = settings.modelName
        let customPrompt = settings.customPrompt
        let reduceImageSize = settings.reduceImageSize
        let maxConcurrentRequests = settings.maxConcurrentRequests
        
        // Concurrency-limited processing loop
        await withTaskGroup(of: AnalysisUpdate.self) { group in
            var activeIndex = 0
            let limit = maxConcurrentRequests
            
            // Spawn initial batch up to concurrency limit
            while activeIndex < limit && activeIndex < indicesToProcess.count {
                let idx = indicesToProcess[activeIndex]
                activeIndex += 1
                let item = imageItems[idx]
                group.addTask {
                    await self.analyzeSingleItem(
                        index: idx,
                        itemURL: item.fileURL,
                        fileName: item.fileName,
                        apiKey: apiKey,
                        modelName: modelName,
                        customPrompt: customPrompt,
                        reduceImageSize: reduceImageSize,
                        manager: self,
                        settings: settings
                    )
                }
            }
            
            // Collect updates and spawn new ones
            var completedCount = 0
            while let update = await group.next() {
                completedCount += 1
                
                self.applyUpdate(update, certaintyThreshold: settings.certaintyThreshold)
                self.currentProgress = Double(completedCount) / Double(indicesToProcess.count)
                
                // If cancelled, stop spawning new tasks
                if !self.isProcessing {
                    break
                }
                
                if activeIndex < indicesToProcess.count {
                    let idx = indicesToProcess[activeIndex]
                    activeIndex += 1
                    let item = imageItems[idx]
                    group.addTask {
                        await self.analyzeSingleItem(
                            index: idx,
                            itemURL: item.fileURL,
                            fileName: item.fileName,
                            apiKey: apiKey,
                            modelName: modelName,
                            customPrompt: customPrompt,
                            reduceImageSize: reduceImageSize,
                            manager: self,
                            settings: settings
                        )
                    }
                }
            }
        }
        
        // Phase 1b: Sequential chronological date fallback (interpolation)
        var lastKnownDate: Date? = nil
        
        // Re-evaluate previous successful images first to establish the initial fallback state
        for item in self.imageItems {
            if (item.status == .analyzed || item.status == .completed) && !item.dateIsInherited {
                if let date = item.detectedDate {
                    lastKnownDate = date
                }
            }
        }
        
        // Pass through all images to apply the fallback
        for index in 0..<self.imageItems.count {
            let item = self.imageItems[index]
            if item.status == .analyzed || item.status == .completed {
                if let date = item.detectedDate, !item.dateIsInherited {
                    lastKnownDate = date
                } else if item.detectedDate == nil || item.dateIsInherited {
                    if let previousDate = lastKnownDate {
                        self.imageItems[index].detectedDate = previousDate
                        self.imageItems[index].dateIsInherited = true
                    }
                }
            }
        }
        
        self.isProcessing = false
        self.currentProgress = 1.0
        self.currentProcessingFile = "Done"
    }
    
    private nonisolated func analyzeSingleItem(
        index: Int,
        itemURL: URL,
        fileName: String,
        apiKey: String,
        modelName: String,
        customPrompt: String,
        reduceImageSize: Bool,
        manager: PinmageManager,
        settings: AppSettings
    ) async -> AnalysisUpdate {
        await manager.updateItemStatus(index: index, status: .processing, fileName: fileName)
        
        // 1. Compute image hash for local cache
        let hash = CacheManager.computeHash(for: itemURL) ?? ""
        var geminiResult: GeminiManager.GeminiResult? = nil
        var errorDescription: String? = nil
        
        // 2. Query Cache
        if !hash.isEmpty, let cachedResult = CacheManager.shared.get(hash: hash) {
            geminiResult = cachedResult
        } else {
            // Cache miss - Analyze with AI
            await manager.updateItemStatus(index: index, status: .callingAPI)
            
            // Retry with exponential backoff (up to 3 attempts)
            var attempts = 0
            let maxAttempts = 3
            var delayNanoseconds: UInt64 = 2_000_000_000 // 2 seconds
            
            while attempts < maxAttempts {
                let stillProcessing = await manager.isProcessing
                if !stillProcessing { break }
                do {
                    let response = try await GeminiManager.analyzeImage(
                        fileURL: itemURL,
                        apiKey: apiKey,
                        modelName: modelName,
                        prompt: customPrompt,
                        reduceSize: reduceImageSize
                    )
                    geminiResult = response.result
                    
                    let cost = Self.calculateCost(inputTokens: response.inputTokens, outputTokens: response.outputTokens, model: modelName)
                    await manager.updateSpend(settings: settings, cost: cost)
                    break // success
                } catch {
                    attempts += 1
                    errorDescription = error.localizedDescription
                    print("Attempt \(attempts) failed for \(fileName): \(error.localizedDescription)")
                    let processing = await manager.isProcessing
                    if attempts < maxAttempts && processing {
                        try? await Task.sleep(nanoseconds: delayNanoseconds)
                        delayNanoseconds *= 2
                    }
                }
            }
            
            // Save to local cache on success
            if let result = geminiResult, !hash.isEmpty {
                CacheManager.shared.set(hash: hash, result: result)
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
                geocodedPlace: nil
            )
        }
        
        // 3. Optional CoreLocation/MapKit Geocoding Fallback
        var latitude: Double? = result.latitude
        var longitude: Double? = result.longitude
        var geocodedPlace: String? = nil
        
        if let place = result.place, !place.isEmpty, place.lowercased() != "null" {
            if latitude == nil || longitude == nil {
                await manager.updateItemStatus(index: index, status: .geocoding, place: place)
                
                if let geocoded = await GeocodingManager.geocode(address: place) {
                    latitude = geocoded.coordinate.latitude
                    longitude = geocoded.coordinate.longitude
                    geocodedPlace = geocoded.resolvedName
                }
            } else {
                if let geocoded = await GeocodingManager.geocode(address: place) {
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
            geocodedPlace: geocodedPlace
        )
    }
    
    private func applyUpdate(_ update: AnalysisUpdate, certaintyThreshold: Int) {
        let index = update.index
        guard index < self.imageItems.count else { return }
        
        if update.success, let result = update.result {
            var parsedDate: Date? = nil
            if let dateStr = result.date, !dateStr.isEmpty, dateStr.lowercased() != "null" {
                parsedDate = parseDate(from: dateStr)
            }
            
            let dateCertainty = result.dateCertainty ?? 0
            let locationCertainty = result.locationCertainty ?? 0
            
            self.imageItems[index].detectedDate = parsedDate
            self.imageItems[index].detectedPlace = result.place
            self.imageItems[index].detectedDateString = result.date
            self.imageItems[index].dateCertainty = dateCertainty
            self.imageItems[index].locationCertainty = locationCertainty
            self.imageItems[index].latitude = update.latitude
            self.imageItems[index].longitude = update.longitude
            self.imageItems[index].geocodedPlace = update.geocodedPlace
            self.imageItems[index].dateIsInherited = false
            
            // Default checked state based on certainty threshold
            self.imageItems[index].saveDate = parsedDate != nil && dateCertainty >= certaintyThreshold
            self.imageItems[index].saveLocation = update.latitude != nil && locationCertainty >= certaintyThreshold
            
            self.imageItems[index].status = .analyzed
            self.successfulCount += 1
        } else {
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
        
        let certaintyThreshold = settings.certaintyThreshold
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
                filenamePattern: filenamePattern
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
        filenamePattern: FilenamePattern
    ) async -> Result<URL, Error> {
        do {
            // Determine if we apply date and/or location based on checkboxes
            let dateValid = item.saveDate && item.detectedDate != nil
            let locationValid = item.saveLocation && item.latitude != nil && item.longitude != nil
            
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
            
            // Write Metadata to copy file
            let success = MetadataWriter.updateImageMetadata(
                sourceURL: item.fileURL,
                destinationURL: outputURL,
                date: parsedDate,
                latitude: latitude,
                longitude: longitude
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
    
    private func parseDate(from string: String) -> Date? {
        let cleanStr = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        // Try YYYY-MM-DD
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: cleanStr) { return date }
        
        // Try YYYY-MM
        formatter.dateFormat = "yyyy-MM"
        if let date = formatter.date(from: cleanStr) { return date }
        
        // Try YYYY
        formatter.dateFormat = "yyyy"
        if let date = formatter.date(from: cleanStr) { return date }
        
        return nil
    }
    
    private nonisolated func resolveOutputFilename(fileURL: URL, date: Date?, place: String?, pattern: FilenamePattern) -> String {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        
        var dateStr = ""
        if let date = date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
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
    
    private static func calculateCost(inputTokens: Int, outputTokens: Int, model: String) -> Double {
        let isPro = model.contains("pro")
        let inputRate = isPro ? 1.25 : 0.075
        let outputRate = isPro ? 5.00 : 0.30
        
        return (Double(inputTokens) * inputRate / 1_000_000.0) + (Double(outputTokens) * outputRate / 1_000_000.0)
    }
}

class GeocodingManager {
    struct GeocodedLocation {
        let coordinate: CLLocationCoordinate2D
        let resolvedName: String?
    }

    static func geocode(address: String) async -> GeocodedLocation? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            guard let firstItem = response.mapItems.first else { return nil }
            return GeocodedLocation(
                coordinate: firstItem.placemark.coordinate,
                resolvedName: firstItem.name ?? firstItem.placemark.title
            )
        } catch {
            print("Geocoding error for '\(address)': \(error.localizedDescription)")
            return nil
        }
    }
}
