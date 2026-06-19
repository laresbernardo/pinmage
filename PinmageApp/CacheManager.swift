import Foundation
import CryptoKit

class CacheManager {
    static let shared = CacheManager()
    private let cacheURL: URL
    private var cache: [String: GeminiManager.GeminiResult] = [:]
    private let queue = DispatchQueue(label: "com.pinmage.cachemanager", attributes: .concurrent)
    
    private init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = paths[0].appendingPathComponent("Pinmage", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.cacheURL = appSupport.appendingPathComponent("metadata_cache.json")
        loadCache()
    }
    
    func get(hash: String) -> GeminiManager.GeminiResult? {
        queue.sync { cache[hash] }
    }
    
    func set(hash: String, result: GeminiManager.GeminiResult) {
        queue.async(flags: .barrier) {
            self.cache[hash] = result
            self.saveCache()
        }
    }
    
    func hasCache(hash: String) -> Bool {
        queue.sync { cache[hash] != nil }
    }
    
    func invalidateCache(hash: String) {
        guard !hash.isEmpty else { return }
        queue.async(flags: .barrier) {
            self.cache.removeValue(forKey: hash)
            self.saveCache()
        }
    }
    
    var cacheCount: Int {
        queue.sync { cache.count }
    }
    
    func clearCache() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
            try? FileManager.default.removeItem(at: self.cacheURL)
        }
    }
    
    func clearDateCache() {
        queue.async(flags: .barrier) {
            for (hash, var entry) in self.cache {
                entry.date = nil
                entry.dateCertainty = nil
                self.cache[hash] = entry
            }
            self.saveCache()
        }
    }
    
    func clearLocationCache() {
        queue.async(flags: .barrier) {
            for (hash, var entry) in self.cache {
                entry.place = nil
                entry.locationCertainty = nil
                entry.latitude = nil
                entry.longitude = nil
                self.cache[hash] = entry
            }
            self.saveCache()
        }
    }
    
    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        if let decoded = try? JSONDecoder().decode([String: GeminiManager.GeminiResult].self, from: data) {
            cache = decoded
        }
    }
    
    private func saveCache() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(cache) {
            try? data.write(to: cacheURL)
        }
    }
    
    /// Helper to compute SHA-256 hash of a file efficiently (streaming).
    static func computeHash(for url: URL) -> String? {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        let bufferSize = 64 * 1024 // 64 KB
        
        while true {
            guard let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
