import Foundation
import AppKit

class OllamaManager {
    static let baseURL = "http://localhost:11434"

    struct OllamaModelInfo: Codable, Identifiable, Hashable {
        let name: String
        var id: String { name }
    }

    private struct OllamaTagsResponse: Codable {
        let models: [OllamaModelInfo]
    }

    private struct OllamaGenerateRequest: Codable {
        let model: String
        let prompt: String
        let images: [String]?
        let stream: Bool
        let format: OllamaFormat?
    }

    private struct OllamaFormat: Codable {
        let type: String
        let properties: [String: OllamaProperty]
        let required: [String]
    }

    private struct OllamaProperty: Codable {
        let type: String
        let description: String?
    }

    private struct OllamaGenerateResponse: Codable {
        let response: String
        let done: Bool
        let error: String?
    }

    struct AnalysisResponse {
        let result: GeminiManager.GeminiResult
        let inputTokens: Int
        let outputTokens: Int
    }

    static var isRunning: Bool {
        get async {
            guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                return false
            }
        }
    }

    static func fetchModels() async throws -> [OllamaModelInfo] {
        guard let url = URL(string: "\(baseURL)/api/tags") else {
            throw NSError(domain: "OllamaManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL"])
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "OllamaManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ollama is not running or unreachable"])
        }
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models
    }

    static func analyzeImage(fileURL: URL, modelName: String, prompt: String, processingMode: ProcessingMode, reduceSize: Bool = true) async throws -> AnalysisResponse {
        let fileData: Data
        if reduceSize {
            if let resizedData = ImageResizer.resizeImage(at: fileURL, maxDimension: 2048) {
                fileData = resizedData
            } else {
                guard let origData = try? Data(contentsOf: fileURL) else {
                    throw NSError(domain: "OllamaManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data from \(fileURL.lastPathComponent)"])
                }
                fileData = origData
            }
        } else {
            guard let origData = try? Data(contentsOf: fileURL) else {
                throw NSError(domain: "OllamaManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to read image data from \(fileURL.lastPathComponent)"])
            }
            fileData = origData
        }

        let base64Image = fileData.base64EncodedString()

        var schemaProperties: [String: OllamaProperty] = [:]
        var requiredFields: [String] = []
        
        if processingMode == .both || processingMode == .dateOnly {
            schemaProperties["date"] = OllamaProperty(type: "string", description: "The clean date in YYYY-MM-DD format (or partial YYYY-MM or YYYY if precise date is unknown), or null if totally unknown. Do NOT write explanations or extra words here.")
            schemaProperties["dateExplanation"] = OllamaProperty(type: "string", description: "Optional explanation/reasoning of why this date was chosen. Keep it brief.")
            schemaProperties["dateCertainty"] = OllamaProperty(type: "integer", description: "Confidence/certainty of the date. CRITICAL: MUST be an integer between 0 and 100 ONLY. 0 if date is null. Values like 95, 80, 50 are valid. Values outside 0-100 are INVALID.")
            requiredFields.append(contentsOf: ["date", "dateCertainty"])
        }
        
        if processingMode == .both || processingMode == .locationOnly {
            schemaProperties["place"] = OllamaProperty(type: "string", description: "The most specific recognizable place name identified in the image, followed by city and country. For example: 'Instituto Cumbres de Caracas, Caracas, Venezuela' rather than just 'Caracas'. Include the landmark/institution/building name when identifiable.")
            schemaProperties["locationExplanation"] = OllamaProperty(type: "string", description: "Explanation of why this location was chosen, what visual or textual clues were used to identify the place. Keep it brief. ONLY location-related reasoning, do NOT include date reasoning here.")
            schemaProperties["locationCertainty"] = OllamaProperty(type: "integer", description: "Confidence/certainty of the location/place. CRITICAL: MUST be an integer between 0 and 100 ONLY. 0 if place is null. Values like 95, 80, 50 are valid. Values outside 0-100 are INVALID.")
            schemaProperties["latitude"] = OllamaProperty(type: "number", description: "Approximate latitude of the identified location in decimal degrees (e.g. 10.4806). Only provide if you are reasonably confident about the location. Return null if unknown.")
            schemaProperties["longitude"] = OllamaProperty(type: "number", description: "Approximate longitude of the identified location in decimal degrees (e.g. -66.9036). Only provide if you are reasonably confident about the location. Return null if unknown.")
            requiredFields.append(contentsOf: ["place", "locationCertainty"])
        }
        
        let schema = OllamaFormat(
            type: "object",
            properties: schemaProperties,
            required: requiredFields
        )
        
        var finalPrompt = prompt
        if processingMode == .dateOnly {
            finalPrompt += "\n\nIMPORTANT: You only need to determine the date when the photo was taken. Do not attempt to analyze or extract location/place details."
        } else if processingMode == .locationOnly {
            finalPrompt += "\n\nIMPORTANT: You only need to determine the location/place where the photo was taken. Do not attempt to analyze or extract the date."
        }
        
        let requestBody = OllamaGenerateRequest(
            model: modelName,
            prompt: finalPrompt,
            images: [base64Image],
            stream: false,
            format: schema
        )

        guard let url = URL(string: "\(baseURL)/api/generate") else {
            throw NSError(domain: "OllamaManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OllamaManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OllamaManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Ollama API Error (\(httpResponse.statusCode)): \(errorText)"])
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(OllamaGenerateResponse.self, from: data)

        if let error = apiResponse.error {
            throw NSError(domain: "OllamaManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Ollama error: \(error)"])
        }

        guard let resultData = apiResponse.response.data(using: .utf8) else {
            throw NSError(domain: "OllamaManager", code: 8, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response text as UTF-8"])
        }

        let result = try decoder.decode(GeminiManager.GeminiResult.self, from: resultData)

        return AnalysisResponse(result: result, inputTokens: 0, outputTokens: 0)
    }
}
