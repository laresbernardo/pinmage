import SwiftUI
import CoreLocation
import Combine

class PinmageManager: ObservableObject {
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
        
        DispatchQueue.main.async {
            self.imageItems = allItems
        }
    }
    
    func removeImage(id: UUID) {
        DispatchQueue.main.async {
            self.imageItems.removeAll { $0.id == id }
        }
    }
    
    func clearAll() {
        DispatchQueue.main.async {
            self.imageItems.removeAll()
            self.currentProgress = 0.0
            self.currentProcessingFile = ""
            self.totalProcessedCount = 0
            self.successfulCount = 0
            self.failedCount = 0
        }
    }
    
    func stopProcessing() {
        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }
    
    /// Main processing loop
    func startProcessing(settings: AppSettings) async {
        guard !isProcessing else { return }
        
        // Check API key
        if settings.apiKey.isEmpty {
            DispatchQueue.main.async {
                for i in 0..<self.imageItems.count {
                    if self.imageItems[i].status == .pending {
                        self.imageItems[i].status = .failed
                        self.imageItems[i].errorMessage = "API Key is missing. Please set it in Settings."
                    }
                }
            }
            return
        }
        
        DispatchQueue.main.async {
            self.isProcessing = true
            self.totalProcessedCount = 0
            self.successfulCount = 0
            self.failedCount = 0
        }
        
        var lastKnownDate: Date? = nil
        
        // Look up if we already have a previous item in the array that succeeded
        for item in imageItems {
            if item.status == .completed, let date = item.detectedDate {
                lastKnownDate = date
            }
        }
        
        for index in 0..<imageItems.count {
            // Check if processing was cancelled
            if !isProcessing { break }
            
            let item = imageItems[index]
            if item.status == .completed {
                continue // Skip already done items
            }
            
            DispatchQueue.main.async {
                self.currentProcessingFile = item.fileName
                self.imageItems[index].status = .processing
                self.currentProgress = Double(index) / Double(self.imageItems.count)
            }
            
            do {
                // Step 1: AI Call
                DispatchQueue.main.async {
                    self.imageItems[index].status = .callingAPI
                }
                
                let geminiResult = try await GeminiManager.analyzeImage(
                    fileURL: item.fileURL,
                    apiKey: settings.apiKey,
                    modelName: settings.modelName,
                    prompt: settings.customPrompt
                )
                
                // Parse date
                var parsedDate: Date? = nil
                var isInherited = false
                
                if let dateStr = geminiResult.date, !dateStr.isEmpty, dateStr.lowercased() != "null" {
                    parsedDate = parseDate(from: dateStr)
                }
                
                if parsedDate == nil {
                    // Chronological date fallback (use previous known date)
                    if let previousDate = lastKnownDate {
                        parsedDate = previousDate
                        isInherited = true
                        print("Inheriting date \(previousDate) for \(item.fileName)")
                    }
                } else {
                    // Update the running last known date
                    lastKnownDate = parsedDate
                }
                
                // Parse coordinates
                var latitude: Double? = geminiResult.latitude
                var longitude: Double? = geminiResult.longitude
                
                // Step 2: Geocoding Fallback if coordinates missing but place is found
                if let place = geminiResult.place, !place.isEmpty, place.lowercased() != "null" {
                    if latitude == nil || longitude == nil {
                        DispatchQueue.main.async {
                            self.imageItems[index].status = .geocoding
                            self.imageItems[index].detectedPlace = place
                        }
                        
                        if let coords = await GeocodingManager.geocode(address: place) {
                            latitude = coords.latitude
                            longitude = coords.longitude
                        }
                    }
                }
                
                // Step 3: Setup output folder and path
                DispatchQueue.main.async {
                    self.imageItems[index].status = .writing
                    self.imageItems[index].detectedDate = parsedDate
                    self.imageItems[index].detectedPlace = geminiResult.place
                    self.imageItems[index].detectedDateString = geminiResult.date
                    self.imageItems[index].latitude = latitude
                    self.imageItems[index].longitude = longitude
                    self.imageItems[index].dateIsInherited = isInherited
                }
                
                let outputFolderURL: URL
                if !settings.outputFolderPath.isEmpty {
                    outputFolderURL = URL(fileURLWithPath: settings.outputFolderPath)
                } else {
                    // Default is same directory as the original file
                    outputFolderURL = item.fileURL.deletingLastPathComponent()
                }
                
                // Create output folder if it doesn't exist
                try FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true, attributes: nil)
                
                let outputURL: URL
                if outputFolderURL.path == item.fileURL.deletingLastPathComponent().path {
                    // Avoid overwriting by adding suffix
                    let baseName = item.fileURL.deletingPathExtension().lastPathComponent
                    let ext = item.fileURL.pathExtension
                    outputURL = outputFolderURL.appendingPathComponent("\(baseName)_processed.\(ext)")
                } else {
                    outputURL = outputFolderURL.appendingPathComponent(item.fileName)
                }
                
                // Step 4: Write Metadata to copy file
                let success = MetadataWriter.updateImageMetadata(
                    sourceURL: item.fileURL,
                    destinationURL: outputURL,
                    date: parsedDate,
                    latitude: latitude,
                    longitude: longitude
                )
                
                if success {
                    DispatchQueue.main.async {
                        self.imageItems[index].status = .completed
                        self.imageItems[index].outputURL = outputURL
                        self.successfulCount += 1
                        self.totalProcessedCount += 1
                    }
                } else {
                    throw NSError(domain: "PinmageManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Failed to compile/save final image metadata"])
                }
                
            } catch {
                print("Error processing file \(item.fileName): \(error)")
                DispatchQueue.main.async {
                    self.imageItems[index].status = .failed
                    self.imageItems[index].errorMessage = error.localizedDescription
                    self.failedCount += 1
                    self.totalProcessedCount += 1
                }
            }
        }
        
        DispatchQueue.main.async {
            self.isProcessing = false
            self.currentProgress = 1.0
            self.currentProcessingFile = "Done"
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
}

class GeocodingManager {
    static func geocode(address: String) async -> CLLocationCoordinate2D? {
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.geocodeAddressString(address)
            return placemarks.first?.location?.coordinate
        } catch {
            print("Geocoding error for '\(address)': \(error.localizedDescription)")
            return nil
        }
    }
}
