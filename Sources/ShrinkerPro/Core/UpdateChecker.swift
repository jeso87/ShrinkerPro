import Foundation

/// Outcome of a `UpdateChecker.check()`. `.notConfigured` means the app has
/// no public repository yet (see `UpdateChecker.repository`) — deliberately
/// distinct from `.upToDate` so callers *could* tell the two apart, even
/// though the shipped UI currently treats only `.available` as actionable.
enum UpdateStatus: Equatable, Sendable {
    case upToDate
    case available(version: String, url: URL)
    case notConfigured
}

/// Checks the GitHub releases API for a newer tag than the running build.
/// Deliberately minimal — no auto-install, no background download, just
/// "here's a newer version, here's the page for it". Sparkle is the
/// follow-on if silent updates are ever wanted; that is out of scope here.
///
/// `repository` ("owner/repo") is read from the Info.plist key
/// `SPRepository`, which is an empty string until Shrinker Pro has a public
/// GitHub home. An empty/whitespace/missing value maps to `nil`, and `nil`
/// means the check is inert: `check()` returns `.notConfigured` without
/// making any network request. Do not hardcode a repository here — that is
/// the whole point of this gate.
struct UpdateChecker: Sendable {

    let repository: String?

    init(repository: String? = Bundle.main.object(forInfoDictionaryKey: "SPRepository") as? String) {
        let trimmed = repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repository = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Never throws and never surfaces an error to the caller: a network
    /// failure, timeout, or malformed response all resolve to `.upToDate`.
    /// A background version check is not worth interrupting the user over.
    func check() async -> UpdateStatus {
        guard let repository,
              let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")
        else { return .notConfigured }

        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            return .upToDate
        }

        guard let release = Self.parseRelease(data: data) else { return .upToDate }
        guard Self.compare(current: current, latestTag: release.tag) else { return .upToDate }

        let page = release.htmlURL ?? URL(string: "https://github.com/\(repository)/releases")!
        return .available(version: release.tag, url: page)
    }

    /// Pulls `tag_name` (and, if present, `html_url`) out of a GitHub
    /// releases-API JSON payload. Pure and network-free so it can be unit
    /// tested directly against fixed JSON strings. Returns `nil` for
    /// malformed JSON or a payload missing `tag_name`.
    static func parseRelease(data: Data) -> (tag: String, htmlURL: URL?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        let htmlURL = (json["html_url"] as? String).flatMap(URL.init(string:))
        return (tag, htmlURL)
    }

    /// True only when `latestTag` is a strictly newer semantic version than
    /// `current`. Compares component-by-component numerically (not
    /// lexicographically), so "1.10.0" correctly beats "1.9.0" — a plain
    /// string comparison would get that backwards. A missing trailing
    /// component is treated as 0, so "2.0" beats "1.0.0". An optional
    /// leading "v" is stripped from either side. Any component that isn't a
    /// non-negative integer (including an empty string) makes that side
    /// unparsable, and an unparsable `current` or `latestTag` returns false.
    static func compare(current: String, latestTag: String) -> Bool {
        guard let latest = versionComponents(latestTag), let now = versionComponents(current) else {
            return false
        }
        for index in 0..<max(latest.count, now.count) {
            let l = index < latest.count ? latest[index] : 0
            let n = index < now.count ? now[index] : 0
            if l != n { return l > n }
        }
        return false
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let cleaned = value.hasPrefix("v") ? String(value.dropFirst()) : value
        guard !cleaned.isEmpty else { return nil }
        let pieces = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = pieces.map { Int($0) }
        guard !numbers.contains(where: { $0 == nil }) else { return nil }
        return numbers.compactMap { $0 }
    }
}
