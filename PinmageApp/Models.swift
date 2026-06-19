import SwiftUI
import Combine

enum ProcessStatus: String, CaseIterable {
    case pending = "Pending"
    case processing = "Processing"
    case callingAPI = "Analyzing with AI"
    case geocoding = "Geocoding Location"
    case analyzed = "AI Analysis Done"
    case writing = "Saving File & Metadata"
    case completed = "Completed"
    case failed = "Failed"
    
    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .callingAPI: return "sparkles"
        case .geocoding: return "mappin.and.ellipse"
        case .analyzed: return "doc.text.magnifyingglass"
        case .writing: return "square.and.arrow.down"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing, .callingAPI, .geocoding, .writing: return .orange
        case .analyzed: return .blue
        case .completed: return .emerald
        case .failed: return .red
        }
    }
}

struct ImageItem: Identifiable, Equatable {
    let id = UUID()
    let fileURL: URL
    var fileName: String {
        fileURL.lastPathComponent
    }
    var status: ProcessStatus = .pending
    var errorMessage: String? = nil
    
    var detectedDateString: String? = nil
    var detectedDate: Date? = nil
    var detectedPlace: String? = nil
    var dateCertainty: Int? = nil
    var locationCertainty: Int? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var dateIsInherited: Bool = false
    var outputURL: URL? = nil
    
    // Existing GPS from file metadata
    var existingLatitude: Double? = nil
    var existingLongitude: Double? = nil
    var hasExistingCoordinates: Bool { existingLatitude != nil && existingLongitude != nil }
    
    // User acceptance & Geocoded Reference Place name
    var saveDate: Bool = false
    var saveLocation: Bool = false
    var geocodedPlace: String? = nil
    
    // Per-image hint to help the AI
    var hint: String = ""
    
    // SHA-256 hash of the file for cache lookups
    var cacheHash: String = ""
    var isCached: Bool { !cacheHash.isEmpty }
    
    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum AIProvider: String, CaseIterable, Codable {
    case gemini = "Google Gemini"
    case ollama = "Ollama (Local)"
}

enum FilenamePattern: String, CaseIterable, Identifiable {
    case original = "Keep Original Name"
    case dateAndName = "Prepend Date (YYYYMMDD_Name)"
    case fullArchive = "Archive Format (YYYYMMDD_Name_Location)"
    
    var id: String { rawValue }
}

@MainActor class AppSettings: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "pinmage_api_key")
        }
    }
    @Published var provider: AIProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "pinmage_ai_provider")
        }
    }
    @Published var modelName: String {
        didSet {
            UserDefaults.standard.set(modelName, forKey: "pinmage_model_name")
        }
    }
    @Published var outputFolderPath: String {
        didSet {
            UserDefaults.standard.set(outputFolderPath, forKey: "pinmage_output_folder")
        }
    }
    @Published var overwriteOriginals: Bool {
        didSet {
            UserDefaults.standard.set(overwriteOriginals, forKey: "pinmage_overwrite_originals")
        }
    }
    @Published var filenamePattern: FilenamePattern {
        didSet {
            UserDefaults.standard.set(filenamePattern.rawValue, forKey: "pinmage_filename_pattern")
        }
    }
    @Published var customPrompt: String {
        didSet {
            UserDefaults.standard.set(customPrompt, forKey: "pinmage_custom_prompt")
        }
    }
    @Published var certaintyThreshold: Int {
        didSet {
            UserDefaults.standard.set(certaintyThreshold, forKey: "pinmage_certainty_threshold")
        }
    }
    @Published var reduceImageSize: Bool {
        didSet {
            UserDefaults.standard.set(reduceImageSize, forKey: "pinmage_reduce_image_size")
        }
    }
    @Published var maxConcurrentRequests: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrentRequests, forKey: "pinmage_max_concurrent_requests")
        }
    }
    @Published var cumulativeSpend: Double {
        didSet {
            UserDefaults.standard.set(cumulativeSpend, forKey: "pinmage_cumulative_spend")
        }
    }
    @Published var skipExistingCoordinates: Bool {
        didSet {
            UserDefaults.standard.set(skipExistingCoordinates, forKey: "pinmage_skip_existing_coordinates")
        }
    }
    @Published var extrapolateDates: Bool {
        didSet {
            UserDefaults.standard.set(extrapolateDates, forKey: "pinmage_extrapolate_dates")
        }
    }
    @Published var locationHint: String {
        didSet {
            UserDefaults.standard.set(locationHint, forKey: "pinmage_location_hint")
        }
    }
    
    func resetCumulativeSpend() {
        cumulativeSpend = 0.0
    }
    
    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "pinmage_api_key") ?? ""
        let storedProvider = UserDefaults.standard.string(forKey: "pinmage_ai_provider") ?? ""
        self.provider = AIProvider(rawValue: storedProvider) ?? .gemini
        self.modelName = UserDefaults.standard.string(forKey: "pinmage_model_name") ?? "gemini-3.1-flash-lite"
        self.outputFolderPath = UserDefaults.standard.string(forKey: "pinmage_output_folder") ?? ""
        self.overwriteOriginals = UserDefaults.standard.bool(forKey: "pinmage_overwrite_originals")
        let rawPattern = UserDefaults.standard.string(forKey: "pinmage_filename_pattern") ?? ""
        self.filenamePattern = FilenamePattern(rawValue: rawPattern) ?? .original
        self.customPrompt = UserDefaults.standard.string(forKey: "pinmage_custom_prompt") ?? "Analyze this image. It may be a scanned page containing multiple photos or a single photo. Identify any written text (captions, notes, dates, place names) AND visually recognize landmarks, architecture, signs, geographic features, or any other visual clues to determine:\n1. The approximate or exact date when the photo(s) were taken.\n2. The location/place name (city, country, landmark, address, region) where the photo was taken, as specific as possible.\n\nPrioritize written text when available, but use visual recognition of landmarks and scenery as supporting evidence. Be as accurate as possible. Return null for date or place if completely unknown.\n\nIMPORTANT: When identifying the place, use a well-known canonical name (e.g., \"Eiffel Tower, Paris, France\" rather than \"that tower in Paris\" or vague descriptions). This ensures the location can be accurately geocoded.\n\nIMPORTANT certainty calibration guidelines:\n- Only report certainty above 90% if the date or location is explicitly and clearly visible in the image content (e.g., a handwritten caption, a printed date stamp from film development in the corner of a photo, a prominent sign).\n- If you are inferring from context clues, clothing, cars, or other indirect evidence, report lower certainty (30-70%).\n- Printed date stamps in the corner of old photos ARE part of the original photo content — treat them as high certainty.\n- Digital watermarks, copyright overlays, software branding logos, or text that appears digitally overlaid/post-processed rather than physically printed on the photo should be ignored.\n- If uncertain, report lower certainty rather than guessing confidently."
        
        let storedThreshold = UserDefaults.standard.integer(forKey: "pinmage_certainty_threshold")
        self.certaintyThreshold = storedThreshold == 0 ? 80 : storedThreshold
        
        // Defaults to true if value is not set yet in UserDefaults
        if UserDefaults.standard.object(forKey: "pinmage_reduce_image_size") == nil {
            self.reduceImageSize = true
        } else {
            self.reduceImageSize = UserDefaults.standard.bool(forKey: "pinmage_reduce_image_size")
        }
        
        let storedConcurrent = UserDefaults.standard.integer(forKey: "pinmage_max_concurrent_requests")
        self.maxConcurrentRequests = storedConcurrent == 0 ? 3 : storedConcurrent
        
        self.cumulativeSpend = UserDefaults.standard.double(forKey: "pinmage_cumulative_spend")
        
        if UserDefaults.standard.object(forKey: "pinmage_skip_existing_coordinates") == nil {
            self.skipExistingCoordinates = true
        } else {
            self.skipExistingCoordinates = UserDefaults.standard.bool(forKey: "pinmage_skip_existing_coordinates")
        }
        
        if UserDefaults.standard.object(forKey: "pinmage_extrapolate_dates") == nil {
            self.extrapolateDates = false
        } else {
            self.extrapolateDates = UserDefaults.standard.bool(forKey: "pinmage_extrapolate_dates")
        }
        
        self.locationHint = UserDefaults.standard.string(forKey: "pinmage_location_hint") ?? ""
    }
}

extension Color {
    static let emerald = Color(red: 16/255, green: 185/255, blue: 129/255)
}

