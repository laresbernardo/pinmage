import Foundation

class GeminiManager {
    struct GeminiResult: Codable {
        var date: String?
        var dateExplanation: String?
        var dateCertainty: Int?
        var place: String?
        var locationExplanation: String?
        var locationCertainty: Int?
        var latitude: Double?
        var longitude: Double?
        
        var dateAnalyzed: Bool? = false
        var locationAnalyzed: Bool? = false
    }
    
    // API request structure
    private struct RequestBody: Codable {
        struct Content: Codable {
            struct Part: Codable {
                struct InlineData: Codable {
                    let mimeType: String
                    let data: String
                }
                let text: String?
                let inlineData: InlineData?
            }
            let parts: [Part]
        }
        struct GenerationConfig: Codable {
            struct Schema: Codable {
                struct Property: Codable {
                    let type: String
                    let description: String?
                }
                let type: String
                let properties: [String: Property]
                let required: [String]?
            }
            let responseMimeType: String
            let responseSchema: Schema
        }
        let contents: [Content]
        let generationConfig: GenerationConfig
    }
    
    struct AnalysisResponse {
        let result: GeminiResult
        let inputTokens: Int
        let outputTokens: Int
    }
    
    // API response structure
    private struct ResponseBody: Codable {
        struct Candidate: Codable {
            struct Content: Codable {
                struct Part: Codable {
                    let text: String
                }
                let parts: [Part]
            }
            let content: Content
        }
        struct UsageMetadata: Codable {
            let promptTokenCount: Int
            let candidatesTokenCount: Int
            let totalTokenCount: Int
        }
        let candidates: [Candidate]
        let usageMetadata: UsageMetadata?
    }
    
    static func analyzeImage(fileURL: URL, apiKey: String, modelName: String, prompt: String, processingMode: ProcessingMode, reduceSize: Bool = true) async throws -> AnalysisResponse {
        // 1. Read file data and base64 encode
        let fileData: Data
        var mimeType = getMimeType(for: fileURL)
        
        if reduceSize {
            if let resizedData = ImageResizer.resizeImage(at: fileURL, maxDimension: 2048) {
                fileData = resizedData
                mimeType = "image/jpeg" // resized returns JPEG
            } else {
                guard let origData = try? Data(contentsOf: fileURL) else {
                    throw NSError(domain: "GeminiManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data from \(fileURL.lastPathComponent)"])
                }
                fileData = origData
            }
        } else {
            guard let origData = try? Data(contentsOf: fileURL) else {
                throw NSError(domain: "GeminiManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data from \(fileURL.lastPathComponent)"])
            }
            fileData = origData
        }
        
        let base64Image = fileData.base64EncodedString()
        
        // 2. Prepare schema based on processing mode
        var schemaProperties: [String: RequestBody.GenerationConfig.Schema.Property] = [:]
        var requiredFields: [String] = []
        
        if processingMode == .both || processingMode == .dateOnly {
            schemaProperties["date"] = RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "The clean date in YYYY-MM-DD format (or partial YYYY-MM or YYYY if precise date is unknown), or null if totally unknown. Do NOT include any explanations or parentheses here.")
            schemaProperties["dateExplanation"] = RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "Optional explanation/reasoning of why this date was chosen (e.g. context clues, signs, written notes, clothing). Keep it brief.")
            schemaProperties["dateCertainty"] = RequestBody.GenerationConfig.Schema.Property(type: "INTEGER", description: "Confidence/certainty of the date. CRITICAL: MUST be an integer between 0 and 100 ONLY. 0 if date is null. Values like 95, 80, 50 are valid. Values outside 0-100 are INVALID.")
            requiredFields.append(contentsOf: ["date", "dateCertainty"])
        }
        
        if processingMode == .both || processingMode == .locationOnly {
            schemaProperties["place"] = RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "The most specific recognizable place name identified in the image, followed by city and country. For example: 'Instituto Cumbres de Caracas, Caracas, Venezuela' rather than just 'Caracas'. Include the landmark/institution/building name when identifiable.")
            schemaProperties["locationExplanation"] = RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "Explanation of why this location was chosen, what visual or textual clues were used to identify the place. Keep it brief. ONLY location-related reasoning, do NOT include date reasoning here.")
            schemaProperties["locationCertainty"] = RequestBody.GenerationConfig.Schema.Property(type: "INTEGER", description: "Confidence/certainty of the location/place. CRITICAL: MUST be an integer between 0 and 100 ONLY. 0 if place is null. Values like 95, 80, 50 are valid. Values outside 0-100 are INVALID.")
            schemaProperties["latitude"] = RequestBody.GenerationConfig.Schema.Property(type: "NUMBER", description: "Approximate latitude of the identified location in decimal degrees (e.g. 10.4806). Only provide if you are reasonably confident about the location. Return null if unknown.")
            schemaProperties["longitude"] = RequestBody.GenerationConfig.Schema.Property(type: "NUMBER", description: "Approximate longitude of the identified location in decimal degrees (e.g. -66.9036). Only provide if you are reasonably confident about the location. Return null if unknown.")
            requiredFields.append(contentsOf: ["place", "locationCertainty"])
        }
        
        let schema = RequestBody.GenerationConfig.Schema(
            type: "OBJECT",
            properties: schemaProperties,
            required: requiredFields
        )
        
        var finalPrompt = prompt
        if processingMode == .dateOnly {
            finalPrompt += "\n\nIMPORTANT: You only need to determine the date when the photo was taken. Do not attempt to analyze or extract location/place details."
        } else if processingMode == .locationOnly {
            finalPrompt += "\n\nIMPORTANT: You only need to determine the location/place where the photo was taken. Do not attempt to analyze or extract the date."
        }
        
        // 3. Assemble request body
        let inlineData = RequestBody.Content.Part.InlineData(mimeType: mimeType, data: base64Image)
        let imagePart = RequestBody.Content.Part(text: nil, inlineData: inlineData)
        let textPart = RequestBody.Content.Part(text: finalPrompt, inlineData: nil)
        
        let content = RequestBody.Content(parts: [textPart, imagePart])
        let config = RequestBody.GenerationConfig(responseMimeType: "application/json", responseSchema: schema)
        
        let body = RequestBody(contents: [content], generationConfig: config)
        
        // 4. Send API request
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "GeminiManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid API URL for model \(modelName)"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GeminiManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "GeminiManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Gemini API Error (\(httpResponse.statusCode)): \(errorText)"])
        }
        
        // 5. Parse response
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(ResponseBody.self, from: data)
        
        guard let textResult = apiResponse.candidates.first?.content.parts.first?.text else {
            throw NSError(domain: "GeminiManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "No content returned from Gemini API"])
        }
        
        // Parse the inner JSON returned as text
        guard let resultData = textResult.data(using: .utf8) else {
            throw NSError(domain: "GeminiManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response text as UTF-8"])
        }
        
        let result = try decoder.decode(GeminiResult.self, from: resultData)
        let inputTokens = apiResponse.usageMetadata?.promptTokenCount ?? (reduceSize ? 258 : 410)
        let outputTokens = apiResponse.usageMetadata?.candidatesTokenCount ?? 80
        
        return AnalysisResponse(result: result, inputTokens: inputTokens, outputTokens: outputTokens)
    }
    
    private static func getMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "image/jpeg"
        }
    }
}
