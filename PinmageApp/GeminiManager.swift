import Foundation

class GeminiManager {
    struct GeminiResult: Codable {
        let date: String?
        let place: String?
        let latitude: Double?
        let longitude: Double?
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
        let candidates: [Candidate]
    }
    
    static func analyzeImage(fileURL: URL, apiKey: String, modelName: String, prompt: String) async throws -> GeminiResult {
        // 1. Read file data and base64 encode
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw NSError(domain: "GeminiManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data from \(fileURL.lastPathComponent)"])
        }
        
        let base64Image = fileData.base64EncodedString()
        let mimeType = getMimeType(for: fileURL)
        
        // 2. Prepare schema
        let schema = RequestBody.GenerationConfig.Schema(
            type: "OBJECT",
            properties: [
                "date": RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "Date in YYYY-MM-DD format (or partial YYYY-MM or YYYY if precise date is unknown), or null if totally unknown"),
                "place": RequestBody.GenerationConfig.Schema.Property(type: "STRING", description: "Location name, landmark, city, country, or null if totally unknown"),
                "latitude": RequestBody.GenerationConfig.Schema.Property(type: "NUMBER", description: "Deduced latitude (double), or null if unknown"),
                "longitude": RequestBody.GenerationConfig.Schema.Property(type: "NUMBER", description: "Deduced longitude (double), or null if unknown")
            ],
            required: ["date", "place", "latitude", "longitude"]
        )
        
        // 3. Assemble request body
        let inlineData = RequestBody.Content.Part.InlineData(mimeType: mimeType, data: base64Image)
        let imagePart = RequestBody.Content.Part(text: nil, inlineData: inlineData)
        let textPart = RequestBody.Content.Part(text: prompt, inlineData: nil)
        
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
        return result
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
