import Foundation
import AppKit
import os.log

private let updateLog = OSLog(subsystem: "com.inhaq.fluent", category: "Updates")

/// Thrown when `hdiutil attach` succeeded but the resulting mount could not be
/// resolved or torn down, so a volume may still be attached.
///
/// The distinction matters to cleanup: deleting the backing `.dmg` out from
/// under a live volume is what turns a leaked mount into an unreadable one, so a
/// caller seeing this must keep the file.
struct DiskImageMountLeak: LocalizedError {
    let reason: String
    var errorDescription: String? {
        "The update disk image could not be unmounted (\(reason)). Leaving it in place."
    }
}

// MARK: - Data Models

struct GitHubRelease: Decodable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let publishedAt: String
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

struct SemanticVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("v") || normalized.hasPrefix("V") {
            normalized.removeFirst()
        }

        let withoutBuildMetadata = normalized.split(separator: "+", maxSplits: 1).first.map(String.init) ?? normalized
        let versionAndPrerelease = withoutBuildMetadata
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        let coreComponents = versionAndPrerelease[0].split(separator: ".").map(String.init)

        guard coreComponents.count == 3,
              let major = Int(coreComponents[0]),
              let minor = Int(coreComponents[1]),
              let patch = Int(coreComponents[2]) else {
            return nil
        }

        let parsedPrerelease: [String]
        if versionAndPrerelease.count > 1 {
            let prereleaseRaw = versionAndPrerelease[1]
            guard !prereleaseRaw.isEmpty else { return nil }
            parsedPrerelease = prereleaseRaw
                .split(separator: ".", omittingEmptySubsequences: false)
                .map(String.init)
            guard parsedPrerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        } else {
            parsedPrerelease = []
        }

        self.major = major
        self.minor = minor
        self.patch = patch
        prerelease = parsedPrerelease
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        if lhs.prerelease.isEmpty && rhs.prerelease.isEmpty { return false }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for index in 0..<min(lhs.prerelease.count, rhs.prerelease.count) {
            let left = lhs.prerelease[index]
            let right = rhs.prerelease[index]
            if left == right { continue }

            let leftNumber = Int(left)
            let rightNumber = Int(right)
            switch (leftNumber, rightNumber) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return left < right
            }
        }

        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

private struct SemanticRelease {
    let release: GitHubRelease
    let version: SemanticVersion
    let versionString: String
    let publishedDate: Date
    let releaseDateString: String
}

// MARK: - Update Status

enum UpdateStatus: Equatable {
    case idle
    case downloading
    case installing
    case readyToRelaunch
    case error(String)
}

// MARK: - Update Manager

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    @Published var updateAvailable = false
    @Published var latestRelease: GitHubRelease?
    @Published var latestReleaseVersion: String = ""
    @Published var latestReleaseDate: String = ""
    @Published var isChecking = false
    @Published var downloadProgress: Double?
    @Published var updateStatus: UpdateStatus = .idle
    @Published var lastCheckDate: Date? {
        didSet {
            if let date = lastCheckDate {
                UserDefaults.standard.set(date, forKey: "updateLastCheckDate")
            }
        }
    }

    var autoCheckEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "updateAutoCheckEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "updateAutoCheckEnabled") }
    }

    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSkippedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkippedVersion") }
    }

    private var lastPostTranscriptionReminderVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateLastPostTranscriptionReminderVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastPostTranscriptionReminderVersion") }
    }

    private var lastPostTranscriptionReminderDate: Date? {
        get { UserDefaults.standard.object(forKey: "updateLastPostTranscriptionReminderDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastPostTranscriptionReminderDate") }
    }

    private let releasesURL = URL(string: "https://api.github.com/repos/inhaq/fluent/releases?per_page=100")!
    private let stabilityBufferDays: TimeInterval = 3
    private let checkIntervalSeconds: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private let postTranscriptionReminderInterval: TimeInterval = 24 * 60 * 60 // 1 day
    private var periodicTimer: Timer?
    private var activeDownloadTask: Task<Void, Never>?

    /// Identifies the current download/install operation. Bumped when one starts
    /// and when one is cancelled, so a task that has been superseded or
    /// cancelled can no longer write to the UI.
    private var updateGeneration = 0

    private init() {
        lastCheckDate = UserDefaults.standard.object(forKey: "updateLastCheckDate") as? Date
    }

    // MARK: - Periodic Checks

    func startPeriodicChecks() {
        // Initial check after 5 second delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.shouldAutoCheck() {
                    await self.checkForUpdates(userInitiated: false)
                }
            }
        }

        // Re-evaluate hourly (handles sleep/wake)
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.shouldAutoCheck() {
                    await self.checkForUpdates(userInitiated: false)
                }
            }
        }
        // Exact firing time does not matter for an hourly check; tolerance
        // lets the system coalesce the wakeup with other timers to save power.
        periodicTimer?.tolerance = 300
    }

    private func shouldAutoCheck() -> Bool {
        guard autoCheckEnabled else { return false }
        guard let lastCheck = lastCheckDate else { return true }
        return Date().timeIntervalSince(lastCheck) > checkIntervalSeconds
    }

    // MARK: - Check for Updates

    @MainActor
    func checkForUpdates(userInitiated: Bool) async {
        let currentBuildTag = Bundle.main.infoDictionary?["FluentBuildTag"] as? String
        let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        // Dev builds (no embedded tag): skip auto-checks, but allow manual checks
        if !userInitiated && currentBuildTag == nil {
            return
        }

        isChecking = true
        defer { isChecking = false }

        do {
            var request = URLRequest(url: releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                if userInitiated { showErrorAlert("Could not reach GitHub.") }
                return
            }

            // 404 means no releases exist yet
            if httpResponse.statusCode == 404 {
                lastCheckDate = Date()
                updateAvailable = false
                latestRelease = nil
                latestReleaseVersion = ""
                latestReleaseDate = ""
                if userInitiated { showUpToDateAlert() }
                return
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                if userInitiated { showErrorAlert("GitHub returned status \(httpResponse.statusCode).") }
                return
            }

            let decoder = JSONDecoder()
            let releases = try decoder.decode([GitHubRelease].self, from: data)
            lastCheckDate = Date()

            guard let currentVersion = SemanticVersion(currentVersionString) else {
                updateAvailable = false
                if userInitiated {
                    showErrorAlert("The current app version does not use semantic versioning.")
                }
                return
            }

            let semanticReleases = releaseCandidates(from: releases)
            guard let latestSemanticRelease = semanticReleases.last else {
                updateAvailable = false
                latestRelease = nil
                latestReleaseVersion = ""
                latestReleaseDate = ""
                if userInitiated {
                    showErrorAlert("No semantic version release was found.")
                }
                return
            }

            let latestVersion = latestSemanticRelease.version
            let release = latestSemanticRelease.release
            let includedReleases = semanticReleases
                .filter { currentVersion < $0.version && $0.version <= latestVersion }
                .map(\.release)
            latestRelease = releaseWithAggregatedNotes(latest: release, includedReleases: includedReleases)
            latestReleaseVersion = latestSemanticRelease.versionString
            latestReleaseDate = latestSemanticRelease.releaseDateString

            // If this is the same or an older semantic version, no update is available.
            if let currentTag = currentBuildTag, release.tagName == currentTag {
                updateAvailable = false
                if userInitiated { showUpToDateAlert() }
                return
            }

            if latestVersion <= currentVersion {
                updateAvailable = false
                if userInitiated { showUpToDateAlert() }
                return
            }

            // Check stability buffer (3 days since published)
            let daysSincePublished = Date().timeIntervalSince(latestSemanticRelease.publishedDate) / (24 * 60 * 60)
            if daysSincePublished < stabilityBufferDays {
                if !userInitiated {
                    // Auto-check: silently skip, too new
                    updateAvailable = false
                    return
                }
                // Manual check: let user know and offer the update anyway
                updateAvailable = true
                showRecentReleaseAlert(daysSincePublished: daysSincePublished)
                return
            }

            // Check if user skipped this version (only for auto checks)
            if !userInitiated && skippedVersion == release.tagName {
                updateAvailable = false
                return
            }

            updateAvailable = true

            if userInitiated {
                showUpdateAlert()
            }
        } catch {
            if userInitiated {
                showErrorAlert("Failed to check for updates: \(error.localizedDescription)")
            }
        }
    }

    private func releaseCandidates(from releases: [GitHubRelease]) -> [SemanticRelease] {
        releases.compactMap { release in
            guard let version = SemanticVersion(release.tagName),
                  let publishedDate = releasePublishedDate(from: release.publishedAt) else {
                return nil
            }

            return SemanticRelease(
                release: release,
                version: version,
                versionString: normalizedVersionString(from: release.tagName),
                publishedDate: publishedDate,
                releaseDateString: displayDateString(from: publishedDate)
            )
        }
        .sorted { lhs, rhs in
            if lhs.version == rhs.version {
                return lhs.publishedDate < rhs.publishedDate
            }
            return lhs.version < rhs.version
        }
    }

    private func releaseWithAggregatedNotes(latest: GitHubRelease, includedReleases: [GitHubRelease]) -> GitHubRelease {
        GitHubRelease(
            tagName: latest.tagName,
            name: latest.name,
            body: aggregatedReleaseNotes(from: includedReleases) ?? latest.body,
            htmlUrl: latest.htmlUrl,
            publishedAt: latest.publishedAt,
            assets: latest.assets
        )
    }

    private func aggregatedReleaseNotes(from releases: [GitHubRelease]) -> String? {
        let notes = releases.reversed().compactMap { releaseNotesBody(from: $0.body) }
        guard !notes.isEmpty else { return nil }
        return notes.joined(separator: "\n\n")
    }

    private func releasePublishedDate(from value: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let iso8601Basic = ISO8601DateFormatter()
        iso8601Basic.formatOptions = [.withInternetDateTime]

        return iso8601.date(from: value) ?? iso8601Basic.date(from: value)
    }

    private func displayDateString(from date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        return dateFormatter.string(from: date)
    }

    private func normalizedVersionString(from tagName: String) -> String {
        tagName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: "^v",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    func shouldShowPostTranscriptionReminder() -> Bool {
        guard updateAvailable,
              let release = latestRelease,
              updateStatus == .idle,
              skippedVersion != release.tagName else {
            return false
        }

        guard lastPostTranscriptionReminderVersion == release.tagName,
              let lastReminder = lastPostTranscriptionReminderDate else {
            return true
        }

        return Date().timeIntervalSince(lastReminder) > postTranscriptionReminderInterval
    }

    func markPostTranscriptionReminderShown() {
        guard let release = latestRelease else { return }
        lastPostTranscriptionReminderVersion = release.tagName
        lastPostTranscriptionReminderDate = Date()
    }

    private func suppressPostTranscriptionReminder(for tagName: String) {
        lastPostTranscriptionReminderVersion = tagName
        lastPostTranscriptionReminderDate = Date()
    }

    private func clearAvailableUpdate() {
        updateAvailable = false
        latestRelease = nil
        latestReleaseVersion = ""
        latestReleaseDate = ""
    }

    // MARK: - Alerts

    func showUpdateAlert() {
        guard let release = latestRelease else { return }

        let alert = NSAlert()
        alert.messageText = "A New Version is Available"
        let versionText = latestReleaseVersion.isEmpty ? release.tagName : "v\(latestReleaseVersion)"
        alert.informativeText = "\(AppName.displayName) \(versionText) was released \(latestReleaseDate).\n\nWould you like to download the update?"
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Remind Me Later")
        alert.addButton(withTitle: "Skip This Version")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall(release: release)
        case .alertSecondButtonReturn:
            showReleaseNotes(for: release)
            showUpdateAlert()
        case .alertThirdButtonReturn:
            suppressPostTranscriptionReminder(for: release.tagName)
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            skippedVersion = release.tagName
            clearAvailableUpdate()
        default:
            break
        }
    }

    private func showRecentReleaseAlert(daysSincePublished: Double) {
        guard let release = latestRelease else { return }

        let hoursAgo = Int(daysSincePublished * 24)
        let ageText = hoursAgo < 1 ? "less than an hour ago" : hoursAgo < 24 ? "\(hoursAgo) hour\(hoursAgo == 1 ? "" : "s") ago" : "\(Int(daysSincePublished)) day\(Int(daysSincePublished) == 1 ? "" : "s") ago"

        let alert = NSAlert()
        alert.messageText = "New Release Available"
        let versionText = latestReleaseVersion.isEmpty ? release.tagName : "v\(latestReleaseVersion)"
        alert.informativeText = "\(AppName.displayName) \(versionText) was released \(ageText). It's very recent — you can download it now or wait a few days for stability.\n\nWould you like to download it?"
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Download Now")
        alert.addButton(withTitle: "What's New")
        alert.addButton(withTitle: "Wait")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            downloadAndInstall(release: release)
        case .alertSecondButtonReturn:
            showReleaseNotes(for: release)
            showRecentReleaseAlert(daysSincePublished: daysSincePublished)
        default:
            suppressPostTranscriptionReminder(for: release.tagName)
            updateAvailable = false
        }
    }

    func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "You're running the latest version of \(AppName.displayName)."
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func showReleaseNotes() {
        guard let release = latestRelease else { return }
        showReleaseNotes(for: release)
    }

    private func showReleaseNotes(for release: GitHubRelease) {
        let alert = NSAlert()
        let versionText = latestReleaseVersion.isEmpty ? release.tagName : "v\(latestReleaseVersion)"
        alert.messageText = "What's New in \(AppName.displayName) \(versionText)"
        alert.informativeText = "Release notes from GitHub."
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.accessoryView = releaseNotesView(text: releaseNotesText(for: release))
        alert.addButton(withTitle: "OK")

        if let releaseURL = URL(string: release.htmlUrl) {
            alert.addButton(withTitle: "Open on GitHub")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }
        } else {
            alert.runModal()
        }
    }

    private func releaseNotesText(for release: GitHubRelease) -> String {
        guard let body = releaseNotesBody(from: release.body) else {
            return "No release notes were published for this version."
        }

        return body
    }

    private func releaseNotesBody(from body: String?) -> String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines),
              !body.isEmpty else {
            return nil
        }

        if let downloadRange = body.range(of: "\n## Download") {
            let notes = String(body[..<downloadRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? nil : notes
        }

        return body
    }

    private func releaseNotesView(text: String) -> NSView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textStorage?.setAttributedString(releaseNotesAttributedString(from: text))

        scrollView.documentView = textView
        return scrollView
    }

    private func releaseNotesAttributedString(from text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bulletFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let headingFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 3)
        let subheadingFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let baseParagraph = NSMutableParagraphStyle()
        baseParagraph.lineSpacing = 2
        baseParagraph.paragraphSpacing = 6

        let bulletParagraph = NSMutableParagraphStyle()
        bulletParagraph.lineSpacing = 2
        bulletParagraph.paragraphSpacing = 4
        bulletParagraph.firstLineHeadIndent = 0
        bulletParagraph.headIndent = 16

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            let font: NSFont
            let paragraphStyle: NSParagraphStyle
            let renderedLine: String

            if trimmedLine.hasPrefix("### ") {
                font = subheadingFont
                paragraphStyle = baseParagraph
                renderedLine = String(trimmedLine.dropFirst(4))
            } else if trimmedLine.hasPrefix("## ") {
                font = headingFont
                paragraphStyle = baseParagraph
                renderedLine = String(trimmedLine.dropFirst(3))
            } else if trimmedLine.hasPrefix("- ") {
                font = bulletFont
                paragraphStyle = bulletParagraph
                renderedLine = "• \(trimmedLine.dropFirst(2))"
            } else {
                font = bodyFont
                paragraphStyle = baseParagraph
                renderedLine = rawLine
            }

            result.append(inlineMarkdownAttributedString(
                from: renderedLine,
                font: font,
                paragraphStyle: paragraphStyle
            ))
            result.append(NSAttributedString(string: "\n"))
        }

        return result
    }

    private func inlineMarkdownAttributedString(
        from text: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remaining = text[...]

        while let markerRange = remaining.range(of: "**") {
            appendPlainMarkdownText(
                String(remaining[..<markerRange.lowerBound]),
                to: result,
                font: font,
                paragraphStyle: paragraphStyle
            )

            let boldStart = markerRange.upperBound
            guard let boldEndRange = remaining[boldStart...].range(of: "**") else {
                appendPlainMarkdownText(
                    String(remaining[markerRange.lowerBound...]),
                    to: result,
                    font: font,
                    paragraphStyle: paragraphStyle
                )
                return result
            }

            let boldText = String(remaining[boldStart..<boldEndRange.lowerBound])
            let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            appendPlainMarkdownText(
                boldText,
                to: result,
                font: boldFont,
                paragraphStyle: paragraphStyle
            )
            remaining = remaining[boldEndRange.upperBound...]
        }

        appendPlainMarkdownText(String(remaining), to: result, font: font, paragraphStyle: paragraphStyle)
        return result
    }

    private func appendPlainMarkdownText(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) {
        result.append(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: paragraphStyle
            ]
        ))
    }

    private func showErrorAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Download and Install

    func cancelDownload() {
        // Retire the generation first: the task being cancelled may not have run
        // a single line yet, and it must not be able to write `.downloading`
        // over the `.idle` set below.
        updateGeneration += 1
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        downloadProgress = nil
        updateStatus = .idle
    }

    func downloadAndInstall(release: GitHubRelease) {
        guard let dmgAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
            return
        }

        guard let downloadURL = URL(string: dmgAsset.browserDownloadUrl) else { return }

        activeDownloadTask?.cancel()
        updateGeneration += 1
        let generation = updateGeneration
        activeDownloadTask = Task {
            await performUpdate(
                downloadURL: downloadURL,
                expectedSize: dmgAsset.size,
                generation: generation
            )
        }
    }

    /// Publishes status for one operation, dropping the write if that operation
    /// has since been cancelled or superseded.
    ///
    /// Without this, a download cancelled between `Task` creation and its first
    /// executed line still set `.downloading` over the `.idle` that
    /// `cancelDownload()` had just written, leaving the UI stuck mid-download.
    private func publish(status: UpdateStatus, generation: Int) {
        guard generation == updateGeneration else { return }
        updateStatus = status
    }

    /// Progress counterpart to ``publish(status:generation:)``. The byte pump
    /// runs detached, so an old one could otherwise keep driving the progress bar
    /// after a cancel or after a newer download had started.
    private func publish(progress: Double?, generation: Int) {
        guard generation == updateGeneration else { return }
        downloadProgress = progress
    }

    private func performUpdate(downloadURL: URL, expectedSize: Int, generation: Int) async {
        // The task may have been cancelled before it ran at all.
        guard !Task.isCancelled, generation == updateGeneration else { return }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("fluent-update-\(UUID().uuidString)")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            publish(status: .error("Failed to create temp directory: \(error.localizedDescription)"), generation: generation)
            return
        }

        let dmgPath = tempDir.appendingPathComponent("Fluent.dmg")

        // MARK: Download phase
        publish(status: .downloading, generation: generation)
        publish(progress: 0, generation: generation)

        do {
            var request = URLRequest(url: downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

            let totalSize = (response as? HTTPURLResponse)
                .flatMap { Int($0.value(forHTTPHeaderField: "Content-Length") ?? "") }
                ?? expectedSize

            let outputHandle = try FileHandle(forWritingTo: {
                fm.createFile(atPath: dmgPath.path, contents: nil)
                return dmgPath
            }())

            // Run the byte-iteration and file I/O off the main thread
            let mgr = self
            let downloadTask = Task.detached {
                var receivedBytes = 0
                let bufferSize = 65_536
                var buffer = Data()
                buffer.reserveCapacity(bufferSize)
                var lastProgressUpdate = CFAbsoluteTimeGetCurrent()

                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    if buffer.count >= bufferSize {
                        outputHandle.write(buffer)
                        receivedBytes += buffer.count
                        buffer.removeAll(keepingCapacity: true)

                        // Throttle progress updates to ~30fps
                        let now = CFAbsoluteTimeGetCurrent()
                        if totalSize > 0 && (now - lastProgressUpdate) >= 0.033 {
                            lastProgressUpdate = now
                            let progress = Double(receivedBytes) / Double(totalSize)
                            await mgr.publish(progress: progress, generation: generation)
                        }
                    }
                }

                // Write remaining bytes
                if !buffer.isEmpty {
                    outputHandle.write(buffer)
                    receivedBytes += buffer.count
                }
                try outputHandle.close()
            }

            // A detached task does not inherit cancellation, and awaiting its
            // `value` is not a cancellation point either — so without this
            // handler, `cancelDownload()` cancelled the parent while the pump
            // kept draining bytes, and the install stages below then ran on a
            // download the user had already cancelled.
            try await withTaskCancellationHandler {
                try await downloadTask.value
            } onCancel: {
                downloadTask.cancel()
            }
            try Task.checkCancellation()
            publish(progress: 1.0, generation: generation)

        } catch is CancellationError {
            try? fm.removeItem(at: tempDir)
            return
        } catch let error as URLError where error.code == .cancelled {
            try? fm.removeItem(at: tempDir)
            return
        } catch {
            publish(status: .error("Download failed: \(error.localizedDescription)"), generation: generation)
            publish(progress: nil, generation: generation)
            try? fm.removeItem(at: tempDir)
            return
        }

        // MARK: Install phase - mount DMG, extract app
        publish(status: .installing, generation: generation)
        publish(progress: nil, generation: generation)

        // tempDir holds the .dmg. While a volume from it is still attached,
        // removing the directory would leave a mounted volume backed by a
        // deleted file — so every exit path, including the error paths, must
        // consult this before cleaning up. It stays true when nothing was ever
        // mounted (e.g. mountDMG itself failed).
        var tempDirIsSafeToRemove = true

        do {
            // Each stage from here on is harder to undo than the last, and the
            // final one moves the running app aside and terminates the process.
            // So every boundary re-checks: `cancelDownload()` can land at any
            // point, and the user cancelling an update must not end with a
            // relaunch into it.
            try Task.checkCancellation()

            let mountPoint: String
            do {
                mountPoint = try await Task.detached {
                    try self.mountDMG(at: dmgPath)
                }.value
            } catch let leak as DiskImageMountLeak {
                // A volume may still be backed by the .dmg in tempDir. Keep the
                // directory: an unreadable mount is worse than wasted disk.
                tempDirIsSafeToRemove = false
                throw leak
            }

            // `hdiutil attach` cannot be interrupted mid-flight, so a cancel
            // during the mount only surfaces here — with a volume attached that
            // has to come back down before the temp dir can go.
            if Task.isCancelled {
                tempDirIsSafeToRemove = await detachDMGAndWait(at: mountPoint)
                removeTempDir(tempDir, ifSafe: tempDirIsSafeToRemove)
                return
            }

            // Detachment must complete *before* the temp dir is removed and
            // before replaceAndRelaunch, which calls NSApp.terminate and does
            // not return. A `defer` cannot be used here: defers cannot await,
            // and a fire-and-forget Task.detached would lose the race against
            // process exit, leaving the volume mounted.
            let stagedApp: URL?
            do {
                stagedApp = try stageAppBundle(fromVolumeAt: mountPoint)
            } catch {
                tempDirIsSafeToRemove = await detachDMGAndWait(at: mountPoint)
                throw error
            }

            tempDirIsSafeToRemove = await detachDMGAndWait(at: mountPoint)
            removeTempDir(tempDir, ifSafe: tempDirIsSafeToRemove)

            // The volume is still attached. replaceAndRelaunch terminates this
            // process, and nothing after that will ever take it down — so the
            // install stops here rather than stranding a mounted image, and the
            // staged copy goes with it.
            guard tempDirIsSafeToRemove else {
                if let stagedApp {
                    try? fm.removeItem(at: stagedApp.deletingLastPathComponent())
                }
                publish(
                    status: .error("The update disk image could not be unmounted. The update was not installed."),
                    generation: generation
                )
                return
            }

            guard let stagedApp else {
                publish(status: .error("No .app found in DMG."), generation: generation)
                return
            }

            // Point of no return: replaceAndRelaunch swaps the app bundle and
            // calls NSApp.terminate. Nothing after it can be undone, so this is
            // the last chance to honour a cancel.
            if Task.isCancelled {
                try? fm.removeItem(at: stagedApp.deletingLastPathComponent())
                return
            }

            // MARK: Replace & relaunch
            publish(status: .readyToRelaunch, generation: generation)
            replaceAndRelaunch(stagedApp: stagedApp, stagingDir: stagedApp.deletingLastPathComponent())

        } catch is CancellationError {
            // cancelDownload() already reset the status; surfacing an error here
            // would contradict it.
            removeTempDir(tempDir, ifSafe: tempDirIsSafeToRemove)
        } catch {
            publish(status: .error("Install failed: \(error.localizedDescription)"), generation: generation)
            removeTempDir(tempDir, ifSafe: tempDirIsSafeToRemove)
        }
    }

    /// Removes the download temp directory, unless a volume backed by the `.dmg`
    /// inside it is still attached. The staged app has already been copied out by
    /// this point, so keeping the directory only costs disk until logout.
    private func removeTempDir(_ tempDir: URL, ifSafe isSafe: Bool) {
        guard isSafe else {
            os_log(
                .error,
                log: updateLog,
                "Leaving %{public}@ in place: DMG did not detach",
                tempDir.path
            )
            return
        }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Copies the `.app` out of a mounted DMG into a fresh staging directory.
    /// Returns `nil` if the volume contains no app bundle. The caller is
    /// responsible for detaching the volume afterwards.
    private func stageAppBundle(fromVolumeAt mountPoint: String) throws -> URL? {
        let fm = FileManager.default
        let volumeURL = URL(fileURLWithPath: mountPoint)
        let contents = try fm.contentsOfDirectory(at: volumeURL, includingPropertiesForKeys: nil)
        guard let appBundle = contents.first(where: { $0.pathExtension == "app" }) else {
            return nil
        }
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("fluent-staged-\(UUID().uuidString)")
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedApp = stagingDir.appendingPathComponent(appBundle.lastPathComponent)
        do {
            try fm.copyItem(at: appBundle, to: stagedApp)
        } catch {
            // Only the caller's `stagedApp` URL ever leads back to this
            // directory, and on a throw the caller never gets one — so a failed
            // copy would strand the staging directory, holding a partial (or
            // very nearly complete) app bundle, until logout.
            try? fm.removeItem(at: stagingDir)
            throw error
        }
        return stagedApp
    }

    /// Detaches a mounted DMG and waits for `hdiutil` to finish, without
    /// blocking the main actor. Returns whether the volume actually detached.
    private func detachDMGAndWait(at mountPoint: String) async -> Bool {
        await Task.detached { Self.detachDMG(at: mountPoint) }.value
    }

    /// Unmounts a DMG. `nonisolated` and `static` so it can never be scheduled
    /// onto the main actor by inheriting isolation from a caller.
    ///
    /// Returns `false` if `hdiutil` could not be launched or exited non-zero —
    /// the caller must not then treat the volume as gone, because deleting the
    /// backing `.dmg` out from under a still-attached volume is what turns a
    /// leaked mount into an unreadable one.
    nonisolated private static func detachDMG(at mountPoint: String) -> Bool {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint, "-quiet"]
        do {
            try detach.run()
        } catch {
            os_log(
                .error,
                log: updateLog,
                "hdiutil detach could not be launched for %{public}@: %{public}@",
                mountPoint,
                error.localizedDescription
            )
            return false
        }
        detach.waitUntilExit()
        guard detach.terminationStatus == 0 else {
            os_log(
                .error,
                log: updateLog,
                "hdiutil detach failed for %{public}@ with exit code %d",
                mountPoint,
                detach.terminationStatus
            )
            return false
        }
        return true
    }

    nonisolated private func mountDMG(at path: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", path.path, "-nobrowse", "-noverify", "-noautoopen", "-plist"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpdateManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "hdiutil attach failed with exit code \(process.terminationStatus)"
            ])
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        // Past this point a volume *is* attached, so every failure below has to
        // either take it back down or say out loud that it could not — throwing
        // a bare error would leave the caller believing nothing was mounted and
        // free to delete the .dmg underneath it.
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw DiskImageMountLeak(reason: "hdiutil attach output could not be parsed")
        }

        if let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first {
            return mountPoint
        }

        // Attached, but nothing is mounted at a path we can use. Take the image
        // back down by device entry so it does not outlive this call.
        //
        // Shortest entry first, and stop at the first success: hdiutil reports
        // the whole disk (/dev/disk4) alongside each of its slices
        // (/dev/disk4s1), and detaching the whole disk takes the slices with it —
        // after which detaching a slice fails because it no longer exists.
        // Requiring every entry to detach reported a leak for an image that was
        // already fully detached, which would strand the temp dir for good.
        let deviceEntries = entities
            .compactMap { $0["dev-entry"] as? String }
            .sorted { $0.count < $1.count }
        guard deviceEntries.contains(where: { Self.detachDMG(at: $0) }) else {
            throw DiskImageMountLeak(reason: "no mount point in hdiutil attach output, and the image could not be detached")
        }

        // Detached cleanly: nothing is attached now, so this is an ordinary
        // failure and the caller may delete the .dmg.
        throw NSError(domain: "UpdateManager", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "No mount point found in hdiutil output"
        ])
    }

    private func replaceAndRelaunch(stagedApp: URL, stagingDir: URL) {
        let currentAppPath = Bundle.main.bundlePath
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let backupPath = currentAppPath + ".bak"

        // Use an argument array instead of string interpolation into a shell
        // script to avoid injection. Move old app to backup first so a failed
        // mv doesn't leave the user with no app.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$5" && mv "$3" "$2" && open "$2" && rm -rf "$4" "$5" \
            || { mv "$5" "$2" 2>/dev/null; rm -rf "$4"; exit 1; }
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script, "--",
                             pid,                // $1
                             currentAppPath,     // $2
                             stagedApp.path,      // $3
                             stagingDir.path,     // $4
                             backupPath]          // $5
        try? process.run()

        // Quit the current app
        NSApp.terminate(nil)
    }
}
