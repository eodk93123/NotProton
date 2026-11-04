// Trial testing is explicitly enabled with an existing CrossOver bottle. CrossOver's
// own wrapper supplies the remaining days; NotProton never creates a trial clock.

import Foundation

enum CrossOverTrial {

    static let bottleKey = "crossOverTrialBottle"
    static let markerName = "notproton-trial"
    static let step = String(localized: "Verify CrossOver trial")
    static let unavailableAdvice = String(localized: "CrossOver could not verify an active trial. Open CrossOver and check the selected bottle, or activate CrossOver, then try again.")

    struct Source: Sendable, Equatable {
        let root: URL
        let bottle: String
    }

    struct Active: Sendable {
        let source: Source
        let daysRemaining: Int
    }

    static func check(
        crossOverRoot: URL,
        defaults: UserDefaults = .standard,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        supported: (URL) -> Bool = { CrossOverSource.inspect(bundle: $0).isUsable },
        run: (String, [String]) throws -> CommandResult = { try Shell.run($0, $1) }
    ) throws -> Active? {
        let source: Source
        if let recorded = try readMarker(in: crossOverRoot) {
            source = recorded
        } else {
            guard let bottle = defaults.string(forKey: bottleKey),
                !bottle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }

            // Preferences opt in only an installed, supported .app. A clone without a
            // marker must not silently become a trial runner when the preference changes.
            let root = crossOverRoot.standardizedFileURL
            let bundle = root.deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            guard bundle.pathExtension == "app",
                root == SupportPaths.crossOverRoot(inBundle: bundle).standardizedFileURL,
                supported(bundle)
            else { return nil }
            source = Source(root: root, bottle: bottle)
        }

        try validate(source)
        let result = try run("/bin/sh", [
            try runScript().path(percentEncoded: false), "check-trial",
            source.root.path(percentEncoded: false), source.bottle,
        ])
        return Active(source: source, daysRemaining: try remainingDays(result))
    }

    // The marker is also consumed by compat_run.sh. Keep its format deliberately
    // small: one absolute source path, one existing bottle name/path, both terminated.
    static func readMarker(in root: URL) throws -> Source? {
        let marker = root.appending(path: markerName)
        guard let attributes = try markerAttributes(marker) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let text = String(data: try Data(contentsOf: marker), encoding: .utf8)
        else { throw failure("trial marker is not a regular UTF-8 file") }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 3, lines[2].isEmpty, lines[0].hasPrefix("/"), safeLine(lines[0]) else {
            throw failure("trial marker must contain exactly two terminated lines")
        }
        let source = Source(root: URL(filePath: lines[0]), bottle: lines[1])
        try validate(source)
        return source
    }

    static func record(_ source: Source?, in root: URL) throws {
        let marker = root.appending(path: markerName)
        guard let source else {
            if try markerAttributes(marker) != nil {
                try FileManager.default.removeItem(at: marker)
            }
            return
        }
        try validate(source)
        let text = "\(source.root.path(percentEncoded: false))\n\(source.bottle)\n"
        try atomicReplace(marker, with: Data(text.utf8), step: step)
    }

    // Direct Wine invocations in the app need the same launch gate as Steam's run
    // script. Unmarked paid/legacy runners do not need the trial payload at all.
    static func requireIfTrialRunner(
        _ root: URL,
        runScript: () throws -> URL = { try InstallPayload.locate().run },
        run: (String, [String]) throws -> CommandResult = { try Shell.run($0, $1) }
    ) throws {
        guard try readMarker(in: root) != nil else { return }
        let result = try run("/bin/sh", [
            try runScript().path(percentEncoded: false), "check-trial-runner",
            root.path(percentEncoded: false),
        ])
        _ = try remainingDays(result)
    }

    private static func validate(_ source: Source) throws {
        let path = source.root.path(percentEncoded: false)
        guard source.root.isFileURL, path.hasPrefix("/"), safeLine(path),
            safeLine(source.bottle),
            !source.bottle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw failure("invalid trial source or bottle") }
    }

    private static func safeLine(_ text: String) -> Bool {
        !text.isEmpty && !text.contains("\n") && !text.contains("\r") && !text.contains("\0")
    }

    private static func markerAttributes(_ marker: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: marker.path(percentEncoded: false))
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func remainingDays(_ result: CommandResult) throws -> Int {
        var output = result.stdout
        if output.hasSuffix("\n") { output.removeLast() }
        guard result.succeeded, !result.outputLost, !output.isEmpty,
            output.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let days = Int(output), days > 0
        else {
            throw failure("trial status failed (\(result.status)): \(result.stdout) \(result.stderr)")
        }
        return days
    }

    private static func failure(_ diagnostic: String) -> StepFailure {
        AppLog.note("trial: \(diagnostic)")
        return StepFailure(step: step, detail: unavailableAdvice)
    }
}
