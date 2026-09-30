import Foundation

@main struct UpdateManifestTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() throws {
        var fields: [String: Any] = ["appID": "com.pinmage.AIInjector", "version": "1.10.0",
            "build": "16", "architectures": ["arm64"], "minimumMacOS": "13.0", "downloadURL": "https://pinmage.bervos.org/Pinmage.dmg"]
        func data() throws -> Data { try JSONSerialization.data(withJSONObject: fields) }
        let release = try UpdateManifest.parse(data())
        require(release.isNewer(than: "1.9.9", build: "15", macOS: "13.0", architecture: "arm64"), "Numeric version order")
        require(!release.isNewer(than: "1.10.0", build: "16", macOS: "13.0", architecture: "arm64"), "Same release")
        require(release.isNewer(than: "1.10.0", build: "15", macOS: "14.0", architecture: "arm64"), "Build order")
        require(!release.isNewer(than: "1.1.0", build: "1", macOS: "12.9", architecture: "arm64"), "Minimum OS")
        require(!release.isNewer(than: "broken", build: "1", macOS: "14.0", architecture: "arm64"), "Invalid bundle version")
        for link in ["http://pinmage.bervos.org/Pinmage.dmg", "https://evil.com/Pinmage.dmg",
                     "https://pinmage.bervos.org.evil.com/Pinmage.dmg", "https://user@pinmage.bervos.org/Pinmage.dmg",
                     "https://pinmage.bervos.org:8443/Pinmage.dmg", "https://pinmage.bervos.org/update.zip",
                     "https://pinmage.bervos.org/Pinmage.dmg?secret=1"] {
            fields["downloadURL"] = link
            require((try? UpdateManifest.parse(data())) == nil, "Reject untrusted download")
        }
        fields["downloadURL"] = "https://pinmage.bervos.org/Pinmage.dmg"
        for version in ["1.2", "-1.2.0", "1.2.x", "1..0", "999999999999.2.0"] {
            fields["version"] = version
            require((try? UpdateManifest.parse(data())) == nil, "Reject invalid release")
        }
        require((try? UpdateManifest.parse(Data(repeating: 32, count: 16_385))) == nil, "Size bound")
        let now = Date(timeIntervalSince1970: 1_000_000)
        require(UpdateCheckPolicy.isDue(lastAttempt: nil, now: now), "First check")
        require(!UpdateCheckPolicy.isDue(lastAttempt: now.addingTimeInterval(-86_399), now: now), "Daily throttle")
        require(UpdateCheckPolicy.isDue(lastAttempt: now.addingTimeInterval(-86_400), now: now), "Daily boundary")
        require(UpdateCheckPolicy.isDue(lastAttempt: now.addingTimeInterval(5), now: now), "Clock correction")
        print("Update manifest validation, numeric ordering, compatibility and throttle tests passed")
    }
}
