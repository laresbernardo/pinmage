import Foundation
import Combine

private final class OfficialUpdateSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The release manifest never needs redirects, including same-origin ones.
        completionHandler(nil)
    }
}

@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var available: UpdateManifest?
    @Published private(set) var isChecking = false
    @Published private(set) var manualStatus: String?
    private let defaults: UserDefaults
    private let session: URLSession
    private var launched = false
    private let lastAttemptKey = "updateCheck.lastAttempt"
    private let dismissedKey = "updateCheck.dismissedReleases"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: OfficialUpdateSessionDelegate(), delegateQueue: nil)
    }

    func checkOnLaunch() async {
        guard !launched else { return }
        launched = true
        await check(manual: false, launch: true)
    }

    func check(manual: Bool = false, launch: Bool = false) async {
        guard !isChecking else { return }
        let now = Date()
        guard manual || launch || UpdateCheckPolicy.isDue(
            lastAttempt: defaults.object(forKey: lastAttemptKey) as? Date, now: now
        ) else { return }
        isChecking = true
        defaults.set(now, forKey: lastAttemptKey)
        manualStatus = nil
        defer { isChecking = false }
        do {
            let (data, response) = try await session.data(from: UpdateManifest.endpoint)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200, response.url == UpdateManifest.endpoint else {
                throw UpdateManifest.ValidationError.invalidManifest
            }
            let release = try UpdateManifest.parse(data)
            let info = Bundle.main.infoDictionary ?? [:]
            let os = ProcessInfo.processInfo.operatingSystemVersion
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let newer = release.isNewer(
                than: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? "",
                macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", architecture: architecture)
            let dismissed = defaults.stringArray(forKey: dismissedKey) ?? []
            available = newer && (manual || !dismissed.contains(release.releaseID)) ? release : nil
            if manual { manualStatus = newer ? nil : "Pinmage is up to date." }
        } catch {
            // Automatic requests are silent, including offline and invalid manifests.
            if manual { manualStatus = "Could not check for updates. Try again later." }
        }
    }

    func dismiss() {
        if let release = available {
            var dismissed = defaults.stringArray(forKey: dismissedKey) ?? []
            if !dismissed.contains(release.releaseID) { dismissed.append(release.releaseID) }
            defaults.set(dismissed, forKey: dismissedKey)
        }
        available = nil
        manualStatus = nil
    }

    func clearStatus() { manualStatus = nil }
}
