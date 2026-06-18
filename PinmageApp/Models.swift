import SwiftUI
import Combine

enum ProcessStatus: String, CaseIterable {
    case pending = "Pending"
    case processing = "Processing"
    case callingAPI = "Analyzing with AI"
    case geocoding = "Geocoding Location"
    case writing = "Saving File & Metadata"
    case completed = "Completed"
    case failed = "Failed"
    
    var iconName: String {
        switch self {
        case .pending: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .callingAPI: return "sparkles"
        case .geocoding: return "mappin.and.ellipse"
        case .writing: return "square.and.arrow.down"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing, .callingAPI, .geocoding, .writing: return .orange
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
    var latitude: Double? = nil
    var longitude: Double? = nil
    var dateIsInherited: Bool = false
    var outputURL: URL? = nil
    
    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id
    }
}

enum FilenamePattern: String, CaseIterable, Identifiable {
    case original = "Keep Original Name"
    case dateAndName = "Prepend Date (YYYY-MM-DD_Name)"
    case fullArchive = "Archive Format (YYYY-MM-DD_Name_Location)"
    
    var id: String { rawValue }
}

class AppSettings: ObservableObject {
    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "pinmage_api_key")
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
    
    init() {
        self.apiKey = UserDefaults.standard.string(forKey: "pinmage_api_key") ?? ""
        self.modelName = UserDefaults.standard.string(forKey: "pinmage_model_name") ?? "gemini-3.5-flash"
        self.outputFolderPath = UserDefaults.standard.string(forKey: "pinmage_output_folder") ?? ""
        self.overwriteOriginals = UserDefaults.standard.bool(forKey: "pinmage_overwrite_originals")
        let rawPattern = UserDefaults.standard.string(forKey: "pinmage_filename_pattern") ?? ""
        self.filenamePattern = FilenamePattern(rawValue: rawPattern) ?? .original
        self.customPrompt = UserDefaults.standard.string(forKey: "pinmage_custom_prompt") ?? "Analyze this image. If it is a scanned page containing multiple photos or a single photo, try to read any written text (captions, notes, dates) or visual cues to extract:\n1. The approximate or exact date when the photo(s) were taken.\n2. The location/place name (city, country, landmark) where the photo was taken.\n\nBe as accurate as possible. Return null for date or place if completely unknown."
    }
}

extension Color {
    static let emerald = Color(red: 16/255, green: 185/255, blue: 129/255)
}

