import Foundation

struct ReleaseNumber: Comparable, Equatable {
    let parts: [Int]

    init?(_ value: String, count: ClosedRange<Int> = 1...3) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard count.contains(fields.count), fields.allSatisfy({
            !$0.isEmpty && $0.count <= 9 && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }) else { return nil }
        parts = fields.map { Int($0)! }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = index < lhs.parts.count ? lhs.parts[index] : 0
            let b = index < rhs.parts.count ? rhs.parts[index] : 0
            if a != b { return a < b }
        }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

struct UpdateManifest: Decodable, Equatable {
    static let endpoint = URL(string: "https://pinmage.bervos.org/version.json")!
    static let appID = "com.pinmage.AIInjector"
    let appID: String
    let version: String
    let build: String
    let minimumMacOS: String
    let downloadURL: URL
    let architectures: [String]
    let notes: String?

    var releaseID: String { "\(version):\(build)" }

    static func isOfficial(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "pinmage.bervos.org" &&
        (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 16_384 else { throw ValidationError.invalidManifest }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.appID == Self.appID,
              ReleaseNumber(manifest.version, count: 3...3) != nil,
              ReleaseNumber(manifest.build, count: 1...1) != nil,
              ReleaseNumber(manifest.minimumMacOS, count: 2...3) != nil,
              !manifest.architectures.isEmpty,
              manifest.architectures.allSatisfy({ ["arm64", "x86_64"].contains($0) }),
              isOfficial(manifest.downloadURL),
              manifest.downloadURL.path.hasSuffix(".dmg"),
              manifest.downloadURL.query == nil, manifest.downloadURL.fragment == nil,
              (manifest.notes?.count ?? 0) <= 2_000 else { throw ValidationError.invalidManifest }
        return manifest
    }

    func isNewer(than version: String, build installedBuild: String, macOS: String, architecture: String) -> Bool {
        guard let current = ReleaseNumber(version, count: 3...3),
              let currentBuild = ReleaseNumber(installedBuild, count: 1...1),
              let release = ReleaseNumber(self.version, count: 3...3),
              let releaseBuild = ReleaseNumber(build, count: 1...1),
              let os = ReleaseNumber(macOS), let minimum = ReleaseNumber(minimumMacOS),
              os >= minimum, architectures.contains(architecture) else { return false }
        return release > current || (release == current && releaseBuild > currentBuild)
    }

    enum ValidationError: Error { case invalidManifest }
}

struct UpdateCheckPolicy {
    static let interval: TimeInterval = 24 * 60 * 60
    static func isDue(lastAttempt: Date?, now: Date) -> Bool {
        guard let lastAttempt else { return true }
        // A clock moved backwards should not disable checks indefinitely.
        return now < lastAttempt || now.timeIntervalSince(lastAttempt) >= interval
    }
}
