import Foundation
import Testing

@testable import NotProtonApp

@Suite("CrossOver trial")
struct CrossOverTrialTests {

    private let script = URL(filePath: "/test payload/run")
    private let source = CrossOverTrial.Source(
        root: URL(filePath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"),
        bottle: "Steam Test"
    )

    private func defaults() throws -> (UserDefaults, String) {
        let name = "np-trial-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("Trial checking requires an explicit bottle and a supported installed app")
    func explicitSupportedOptIn() throws {
        let (preferences, suite) = try defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appending(path: "CrossOver.app")
        let root = SupportPaths.crossOverRoot(inBundle: bundle)
        var calls = 0
        let run: (String, [String]) throws -> CommandResult = { executable, arguments in
            calls += 1
            #expect(executable == "/bin/sh")
            #expect(arguments == [
                script.path(percentEncoded: false), "check-trial",
                root.path(percentEncoded: false), "Steam Test",
            ])
            return CommandResult(status: 0, stdout: "7\n", stderr: "")
        }

        #expect(try CrossOverTrial.check(
            crossOverRoot: root, defaults: preferences, runScript: { script },
            supported: { _ in true }, run: run) == nil)
        preferences.set("Steam Test", forKey: CrossOverTrial.bottleKey)
        #expect(try CrossOverTrial.check(
            crossOverRoot: root, defaults: preferences, runScript: { script },
            supported: { _ in false }, run: run) == nil)
        #expect(try CrossOverTrial.check(
            crossOverRoot: directory.appending(path: "CrossOver"),
            defaults: preferences, runScript: { script },
            supported: { _ in true }, run: run) == nil)
        #expect(calls == 0)

        let checked = try CrossOverTrial.check(
            crossOverRoot: root, defaults: preferences, runScript: { script },
            supported: { candidate in
                #expect(CrossOverSource.same(candidate, bundle))
                return true
            }, run: run)
        let active = try #require(checked)
        #expect(active.daysRemaining == 7)
        #expect(active.source.root == root)
        #expect(active.source.bottle == "Steam Test")
        #expect(calls == 1)
    }

    @Test("A clone keeps its verified source when the global bottle preference changes")
    func recordedSourceWins() throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (preferences, suite) = try defaults()
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("Another bottle", forKey: CrossOverTrial.bottleKey)
        try CrossOverTrial.record(source, in: directory)
        let bytes = try String(
            contentsOf: directory.appending(path: CrossOverTrial.markerName), encoding: .utf8)
        #expect(bytes == "\(source.root.path(percentEncoded: false))\nSteam Test\n")

        let checked = try CrossOverTrial.check(
            crossOverRoot: directory, defaults: preferences, runScript: { script },
            supported: { _ in
                Issue.record("A clone must resolve its source from the marker.")
                return false
            },
            run: { _, arguments in
                #expect(arguments == [
                    script.path(percentEncoded: false), "check-trial",
                    source.root.path(percentEncoded: false), source.bottle,
                ])
                return CommandResult(status: 0, stdout: "3\n", stderr: "")
            })
        let active = try #require(checked)
        #expect(active.source == source)
        #expect(active.daysRemaining == 3)
    }

    @Test("Unmarked runners do not need the trial payload")
    func absentMarkerSkipsGate() throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CrossOverTrial.requireIfTrialRunner(directory, runScript: {
            Issue.record("An unmarked runner must not resolve the trial payload.")
            return script
        }, run: { _, _ in
            Issue.record("An unmarked runner must not invoke a trial check.")
            return CommandResult(status: 1, stdout: "", stderr: "")
        })
    }

    @Test("A marked runner rechecks the trial before a direct Wine launch")
    func markedRunnerChecks() throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CrossOverTrial.record(source, in: directory)
        var calls = 0
        try CrossOverTrial.requireIfTrialRunner(directory, runScript: { script }, run: { executable, arguments in
            calls += 1
            #expect(executable == "/bin/sh")
            #expect(arguments == [
                script.path(percentEncoded: false), "check-trial-runner",
                directory.path(percentEncoded: false),
            ])
            return CommandResult(status: 0, stdout: "1\n", stderr: "")
        })
        #expect(calls == 1)
    }

    @Test("Failed, expired, ambiguous, and lost trial results refuse a launch", arguments: [
        CommandResult(status: 1, stdout: "7\n", stderr: "failed"),
        CommandResult(status: 0, stdout: "0\n", stderr: ""),
        CommandResult(status: 0, stdout: "-1\n", stderr: ""),
        CommandResult(status: 0, stdout: "", stderr: ""),
        CommandResult(status: 0, stdout: "Standard version\n", stderr: ""),
        CommandResult(status: 0, stdout: "7\nunexpected\n", stderr: ""),
        CommandResult(status: 0, stdout: " 7\n", stderr: ""),
        CommandResult(status: 0, stdout: "7\n\n", stderr: ""),
        CommandResult(status: 0, stdout: "7\r\n", stderr: ""),
        CommandResult(status: 0, stdout: "999999999999999999999999\n", stderr: ""),
        CommandResult(status: 0, stdout: "7\n", stderr: "", outputLost: true),
    ])
    func refusesUnverifiedResult(result: CommandResult) throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CrossOverTrial.record(source, in: directory)
        #expect(throws: StepFailure.self) {
            try CrossOverTrial.requireIfTrialRunner(
                directory, runScript: { script }, run: { _, _ in result })
        }
    }

    @Test("Malformed source markers never turn into unmarked runners", arguments: [
        "", "/source\nSteam", "/source\nSteam\nextra\n", "relative\nSteam\n",
        "/source\n\n", "/source\n   \n", "/source\r\nSteam\n", "/source\nSteam\0\n",
    ])
    func refusesMalformedMarker(contents: String) throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(contents.utf8).write(to: directory.appending(path: CrossOverTrial.markerName))
        #expect(throws: StepFailure.self) {
            try CrossOverTrial.requireIfTrialRunner(directory, runScript: {
                Issue.record("Malformed markers must fail before resolving the payload.")
                return script
            })
        }
    }

    @Test("A symbolic link marker is refused, including a dangling link", arguments: [false, true])
    func refusesSymlinkMarker(dangling: Bool) throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "target")
        if !dangling {
            try Data("/source\nSteam\n".utf8).write(to: target)
        }
        let marker = directory.appending(path: CrossOverTrial.markerName)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: target)
        #expect(throws: StepFailure.self) { try CrossOverTrial.readMarker(in: directory) }
        try CrossOverTrial.record(nil, in: directory)
        #expect(try CrossOverTrial.readMarker(in: directory) == nil)
        if !dangling {
            #expect(try Data(contentsOf: target) == Data("/source\nSteam\n".utf8))
        }
    }

    @Test("Trial verification failure cannot start Wine or replace a prefix")
    func refusesDirectToolsBeforeMutation() throws {
        let directory = try scratchDirectory("trial")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = directory.appending(path: "runner")
        let loader = runner.appending(path: "lib/wine/x86_64-unix/wine")
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 99\n".utf8).write(to: loader)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: loader.path(percentEncoded: false))
        try Data("invalid trial marker".utf8).write(to: runner.appending(path: CrossOverTrial.markerName))
        let prefix = WinePrefix(
            appID: "480", name: "Test", library: SteamLibrary(root: directory), lastUsed: nil)
        try FileManager.default.createDirectory(at: prefix.pfx, withIntermediateDirectories: true)
        let saved = prefix.pfx.appending(path: "user.reg")
        try Data("existing prefix".utf8).write(to: saved)
        let pending = prefix.root.appending(path: "pfx.rebuild")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let pendingSave = pending.appending(path: "keep")
        try Data("pending prefix".utf8).write(to: pendingSave)

        for action in [
            { try PrefixTools.launch(.winecfg, in: prefix, runner: runner) },
            { _ = try PrefixTools.recreate(prefix, runner: runner) },
        ] {
            do {
                try action()
                Issue.record("A malformed trial marker allowed a direct Wine operation.")
            } catch let failure as StepFailure {
                #expect(failure.step == CrossOverTrial.step)
            }
        }
        #expect(try Data(contentsOf: saved) == Data("existing prefix".utf8))
        #expect(try Data(contentsOf: pendingSave) == Data("pending prefix".utf8))
    }
}
