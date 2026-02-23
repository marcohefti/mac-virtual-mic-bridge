import Foundation

enum UpdateChannel: String {
    case stable
    case beta

    static let defaultsKey = "micbridge.updateChannel"
    static let envKey = "MICBRIDGE_UPDATE_CHANNEL"

    static func resolve(currentVersion: String) -> UpdateChannel {
        if let envRaw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let envChannel = UpdateChannel(rawValue: envRaw.lowercased())
        {
            return envChannel
        }

        if let storedRaw = UserDefaults.standard.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let storedChannel = UpdateChannel(rawValue: storedRaw.lowercased())
        {
            return storedChannel
        }

        let lowered = currentVersion.lowercased()
        if lowered.contains("beta") || lowered.contains("alpha") || lowered.contains("rc") || lowered.contains("dev") {
            return .beta
        }

        return .stable
    }
}

enum UpdateCheckResult {
    case upToDate(latestVersion: String)
    case updateAvailable(latestVersion: String, releaseURL: URL, archiveURL: URL?, checksumURL: URL?)
    case unavailable(reason: String)
    case failed(message: String)
}

enum UpdateMenuState {
    case unavailable(reason: String)
    case idle(channel: UpdateChannel)
    case checking(channel: UpdateChannel)
    case upToDate(channel: UpdateChannel, latestVersion: String)
    case updateAvailable(channel: UpdateChannel, latestVersion: String, releaseURL: URL, archiveURL: URL?, checksumURL: URL?)
    case failed(channel: UpdateChannel, message: String)

    var statusText: String {
        switch self {
        case let .unavailable(reason):
            return "Updates: Unavailable (\(reason))"
        case let .idle(channel):
            return "Updates: Ready (\(channel.rawValue))"
        case .checking:
            return "Updates: Checking..."
        case let .upToDate(_, latestVersion):
            return "Updates: Up to date (\(latestVersion))"
        case let .updateAvailable(_, latestVersion, _, _, _):
            return "Updates: \(latestVersion) available"
        case .failed:
            return "Updates: Check failed"
        }
    }

    var checkActionTitle: String {
        switch self {
        case let .updateAvailable(_, latestVersion, _, archiveURL, checksumURL):
            if archiveURL != nil, checksumURL != nil {
                return "Install Update \(latestVersion)..."
            }
            return "Open Update \(latestVersion)..."
        default:
            return "Check for Updates..."
        }
    }

    var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }
}

private struct GitHubReleaseRecord: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let publishedAt: Date?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case publishedAt = "published_at"
        case assets
    }
}

private struct SemanticVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case string(String)
    }

    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    init?(_ rawValue: String) {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        if trimmed.isEmpty {
            return nil
        }

        let mainAndBuild = trimmed.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let mainPart = String(mainAndBuild[0])
        let parts = mainPart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)

        let coreComponents = parts[0].split(separator: ".")
        guard coreComponents.count >= 2 && coreComponents.count <= 3 else {
            return nil
        }

        guard
            let major = Int(coreComponents[0]),
            let minor = Int(coreComponents[1])
        else {
            return nil
        }

        let patch: Int
        if coreComponents.count == 3 {
            guard let parsedPatch = Int(coreComponents[2]) else {
                return nil
            }
            patch = parsedPatch
        } else {
            patch = 0
        }

        self.major = major
        self.minor = minor
        self.patch = patch

        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".")
            prerelease = identifiers.map { token in
                if let number = Int(token) {
                    return .numeric(number)
                }
                return .string(token.lowercased())
            }
        } else {
            prerelease = []
        }
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        let count = min(lhs.prerelease.count, rhs.prerelease.count)
        for index in 0..<count {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right {
                continue
            }

            switch (left, right) {
            case let (.numeric(leftValue), .numeric(rightValue)):
                return leftValue < rightValue
            case (.numeric, .string):
                return true
            case (.string, .numeric):
                return false
            case let (.string(leftValue), .string(rightValue)):
                return leftValue < rightValue
            }
        }

        return lhs.prerelease.count < rhs.prerelease.count
    }
}

final class GitHubReleaseUpdateService {
    private let repoSlug: String
    private let currentVersion: String
    private let channel: UpdateChannel
    private let session: URLSession

    init(repoSlug: String, currentVersion: String, channel: UpdateChannel, session: URLSession = .shared) {
        self.repoSlug = repoSlug
        self.currentVersion = currentVersion
        self.channel = channel
        self.session = session
    }

    var updateChannel: UpdateChannel {
        channel
    }

    private func artifactURLs(for release: GitHubReleaseRecord) -> (archive: URL?, checksum: URL?) {
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let expectedArchive = "MicBridge-\(version)-macos.tar.gz"
        let expectedChecksum = "\(expectedArchive).sha256"

        let archive = release.assets.first(where: { $0.name == expectedArchive })?.browserDownloadURL
        let checksum = release.assets.first(where: { $0.name == expectedChecksum })?.browserDownloadURL
        return (archive, checksum)
    }

    func check(completion: @escaping (UpdateCheckResult) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases?per_page=20") else {
            completion(.unavailable(reason: "Invalid release URL"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("micbridge-menubar-update-check", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [self] data, response, error in
            if let error {
                completion(.failed(message: "Network error: \(error.localizedDescription)"))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.failed(message: "Invalid update response"))
                return
            }

            guard (200...299).contains(http.statusCode) else {
                completion(.failed(message: "Update check failed (HTTP \(http.statusCode))"))
                return
            }

            guard let data else {
                completion(.failed(message: "Update response was empty"))
                return
            }

            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let releases = try decoder.decode([GitHubReleaseRecord].self, from: data)

                let filtered = releases.filter { release in
                    guard !release.draft else { return false }
                    if channel == .stable && release.prerelease {
                        return false
                    }
                    return true
                }

                guard !filtered.isEmpty else {
                    completion(.unavailable(reason: "No eligible releases for \(channel.rawValue) channel"))
                    return
                }

                let currentSemantic = SemanticVersion(currentVersion)
                let ranked = filtered.compactMap { release -> (release: GitHubReleaseRecord, semantic: SemanticVersion)? in
                    guard let semantic = SemanticVersion(release.tagName) else { return nil }
                    return (release, semantic)
                }

                let latest: GitHubReleaseRecord
                let latestVersion: String

                if let top = ranked.max(by: { lhs, rhs in
                    if lhs.semantic != rhs.semantic {
                        return lhs.semantic < rhs.semantic
                    }
                    return (lhs.release.publishedAt ?? .distantPast) < (rhs.release.publishedAt ?? .distantPast)
                }) {
                    latest = top.release
                    latestVersion = top.release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                    let artifact = artifactURLs(for: top.release)

                    if let currentSemantic, top.semantic <= currentSemantic {
                        completion(.upToDate(latestVersion: latestVersion))
                    } else {
                        completion(
                            .updateAvailable(
                                latestVersion: latestVersion,
                                releaseURL: latest.htmlURL,
                                archiveURL: artifact.archive,
                                checksumURL: artifact.checksum
                            )
                        )
                    }
                    return
                }

                let fallback = filtered.max { lhs, rhs in
                    (lhs.publishedAt ?? .distantPast) < (rhs.publishedAt ?? .distantPast)
                }

                guard let fallback else {
                    completion(.unavailable(reason: "No release candidates"))
                    return
                }

                latest = fallback
                latestVersion = fallback.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let artifact = artifactURLs(for: latest)
                completion(
                    .updateAvailable(
                        latestVersion: latestVersion,
                        releaseURL: latest.htmlURL,
                        archiveURL: artifact.archive,
                        checksumURL: artifact.checksum
                    )
                )
            } catch {
                completion(.failed(message: "Failed to parse release metadata: \(error.localizedDescription)"))
            }
        }.resume()
    }
}
