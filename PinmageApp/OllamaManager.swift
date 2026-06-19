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

    static func analyzeImage(fileURL: URL, modelName: String, prompt: String, reduceSize: Bool = true) async throws -> AnalysisResponse {
        let fileData: Data
        if reduceSize {
            if let resizedData = ImageResizer.resizeImage(at: fileURL, maxDimension: 1600) {
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

        let schema = OllamaFormat(
            type: "object",
            properties: [
                "date": OllamaProperty(type: "string", description: "Date in YYYY-MM-DD format (or partial YYYY-MM or YYYY if precise date is unknown), or null if totally unknown"),
                "dateCertainty": OllamaProperty(type: "integer", description: "Confidence/certainty of the date, from 0 to 100. 0 if date is null."),
                "place": OllamaProperty(type: "string", description: "Location name, landmark, city, country, or null if totally unknown"),
                "locationCertainty": OllamaProperty(type: "integer", description: "Confidence/certainty of the location/place, from 0 to 100. 0 if place is null."),
                "latitude": OllamaProperty(type: "number", description: "Deduced latitude (double), or null if unknown"),
                "longitude": OllamaProperty(type: "number", description: "Deduced longitude (double), or null if unknown")
            ],
            required: ["date", "dateCertainty", "place", "locationCertainty", "latitude", "longitude"]
        )

        let requestBody = OllamaGenerateRequest(
            model: modelName,
            prompt: prompt,
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
