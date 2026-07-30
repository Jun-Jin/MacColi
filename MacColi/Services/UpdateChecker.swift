import AppKit
import Foundation

/// Checks GitHub Releases for a newer MacColi and, for Homebrew installs,
/// drives the `brew upgrade` that applies it.
///
/// Owned by the App (not SettingsView) so a running upgrade survives the user
/// switching panels — SettingsView is recreated on every visit.
@Observable
@MainActor
final class UpdateChecker {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String)
        case upgrading
        /// `brew upgrade` succeeded. The bundle on disk is the new version, but
        /// this process still runs the old binary until relaunched.
        case relaunchReady
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Whether the app was installed with `brew install --cask maccoli` — decides
    /// whether the update is applied in-app or via the releases page.
    private(set) var isBrewInstall = false
    /// Most recent `brew upgrade` output line, shown while the upgrade runs.
    private(set) var upgradeStatusLine = ""

    static let releasesPage = URL(string: "https://github.com/Jun-Jin/MacColi/releases/latest")!

    /// Quiet launch checks run at most once per day — the fetch avoids the
    /// rate-limited API, but there's still no reason to hit GitHub on every
    /// dev-loop relaunch. Stored on successful fetches only, so an offline
    /// launch retries next time.
    private static let lastCheckKey = "updateCheck.lastSuccess"
    private static let quietInterval: TimeInterval = 24 * 60 * 60

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares the latest release tag against the running version.
    ///
    /// A quiet check (app launch) only surfaces a positive result: failures —
    /// usually just being offline — reset to idle instead of showing an error
    /// nobody asked for.
    func check(userInitiated: Bool = true) async {
        switch phase {
        case .checking, .upgrading, .relaunchReady: return
        default: break
        }
        if !userInitiated,
           let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.quietInterval {
            return
        }
        phase = .checking
        do {
            async let brewInstall = Self.detectBrewInstall()
            let latest = try await Self.fetchLatestVersion()
            isBrewInstall = await brewInstall
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            phase = Self.isNewer(latest, than: currentVersion)
                ? .available(version: latest)
                : .upToDate
        } catch {
            phase = userInitiated
                ? .failed("Update check failed: \(error.localizedDescription)")
                : .idle
        }
    }

    /// Applies the update in place. Homebrew replaces the bundle on disk while
    /// this (old) binary keeps running, so the flow ends in `relaunchReady`
    /// rather than done.
    func upgrade() async {
        guard case .available = phase else { return }
        phase = .upgrading
        upgradeStatusLine = ""
        do {
            try await CLI.shared.runStreamingChecked(
                "brew", ["upgrade", "--cask", "maccoli"]
            ) { line in
                Task { @MainActor in self.upgradeStatusLine = line }
            }
            phase = .relaunchReady
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Starts a fresh instance (the new binary, now that the bundle was
    /// replaced) and exits this one. `open` is a separate process, so it
    /// survives our termination.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// True when this bundle is tracked by the `maccoli` cask — a DMG install
    /// has no cask entry, and `brew` itself may not exist.
    private static func detectBrewInstall() async -> Bool {
        guard let result = try? await CLI.shared.runRaw("brew", ["list", "--cask", "maccoli"])
        else { return false }
        return result.succeeded
    }

    /// Reads the latest version from the releases page's redirect instead of
    /// the REST API: `/releases/latest` answers 3xx with a Location of
    /// `/releases/tag/vX.Y.Z`. The web endpoint is not subject to the API's
    /// 60 unauthenticated requests/hour/IP, which dev-loop relaunches used to
    /// drain until checks 403ed.
    private static func fetchLatestVersion() async throws -> String {
        let (_, response) = try await URLSession.shared.data(
            for: URLRequest(url: releasesPage), delegate: RedirectStopper())
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (300..<400).contains(http.statusCode),
              let location = http.value(forHTTPHeaderField: "Location"),
              let tag = URL(string: location, relativeTo: releasesPage)
                  .map({ $0.lastPathComponent }),
              !tag.isEmpty
        else {
            throw HTTPStatusError(status: http.statusCode)
        }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// A response that wasn't the expected release redirect. Carries the status
    /// so the Settings error line says what GitHub actually answered.
    private struct HTTPStatusError: LocalizedError {
        let status: Int
        var errorDescription: String? { "GitHub answered HTTP \(status)." }
    }

    /// Stops URLSession from following the releases-page redirect, so the 3xx
    /// response — whose Location header carries the version tag — is returned
    /// as-is instead of the page it points to.
    private final class RedirectStopper: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    /// Numeric per-component comparison, so "0.10.0" beats "0.9.1" where a
    /// string compare would not.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }
}
