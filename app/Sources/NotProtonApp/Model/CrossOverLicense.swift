// Checks whether the user's CrossOver install is licensed.
// CodeWeavers, I hope this doesn't bother you. You don't validate
// license when the Wine binary itself is invoked, so I wanted to
// do something to prevent skids from doing really trivial piracy.

import Foundation

enum CrossOverLicense {

    struct Status: Sendable {
        let licensed: Bool
        let detail: String
        // The real reason, for the log.
        let diagnostic: String
        let trial: CrossOverTrial.Source?

        init(
            licensed: Bool, detail: String, diagnostic: String,
            trial: CrossOverTrial.Source? = nil
        ) {
            self.licensed = licensed
            self.detail = detail
            self.diagnostic = diagnostic
            self.trial = trial
        }
    }

    static let defaultSearchDirs: [URL] = {
        let home = URL(filePath: NSHomeDirectory())
        return [
            home.appending(path: "Library/Preferences"),
            URL(filePath: "/Library/Preferences"),
        ]
    }()

    private static let licenseBase = "com.codeweavers.CrossOver"

    static let notActivatedTitle = String(localized: "CrossOver does not appear to be activated.")
    static let trialAdvice = String(localized: "Trial testing requires an existing CrossOver bottle and a positive trial status from CrossOver.")
    static let notActivatedAdvice = "\(String(localized: "Please run CrossOver and try again.")) \(trialAdvice)"
    static var notActivated: String { "\(notActivatedTitle) \(notActivatedAdvice)" }

    static let defaultOpenssl = "/usr/bin/openssl"

    static func check(
        crossOverRoot: URL,
        searchDirs: [URL] = defaultSearchDirs,
        openssl: String = defaultOpenssl,
        trial: (URL) throws -> CrossOverTrial.Active? = { try CrossOverTrial.check(crossOverRoot: $0) }
    ) -> Status {
        var status = evaluate(
            crossOverRoot: crossOverRoot, searchDirs: searchDirs, openssl: openssl
        )
        if !status.licensed {
            do {
                if let active = try trial(crossOverRoot), active.daysRemaining > 0 {
                    status = Status(
                        licensed: true,
                        detail: String(localized: "CrossOver trial days remaining: \(active.daysRemaining)."),
                        diagnostic: "active CrossOver trial (\(active.daysRemaining) days remaining)",
                        trial: active.source
                    )
                }
            } catch {
                status = Status(
                    licensed: false,
                    detail: CrossOverTrial.unavailableAdvice,
                    diagnostic: "\(status.diagnostic); trial verification failed: \(error.localizedDescription)"
                )
            }
        }
        AppLog.note("license: \(status.diagnostic)")
        return status
    }

    private static func evaluate(
        crossOverRoot: URL,
        searchDirs: [URL],
        openssl: String
    ) -> Status {
        let keyFile = crossOverRoot.appending(
            path: "share/crossover/data/tie.pub"
        ).path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: keyFile) else {
            return Status(
                licensed: false,
                detail: notActivated,
                diagnostic: "no verification key in the CrossOver bundle"
            )
        }

        var rejection: String?

        for dir in searchDirs {
            let label = dir.path(percentEncoded: false)
            let license = dir.appending(path: "\(licenseBase).license")
                .path(percentEncoded: false)

            guard FileManager.default.fileExists(atPath: license) else { continue }

            let signatures = sidecars(in: dir)
            guard !signatures.isEmpty else {
                rejection = "the license in \(label) has no signature beside it"
                continue
            }

            var unchecked: String?

            for signature in signatures {
                let result: CommandResult
                do {
                    result = try Shell.run(openssl, [
                        "dgst", signature.digest, "-verify", keyFile,
                        "-signature", signature.path, license,
                    ])
                } catch {
                    return Status(
                        licensed: false,
                        detail: notActivated,
                        diagnostic: "could not run \(openssl) to verify the license"
                    )
                }

                if result.succeeded {
                    return Status(
                        licensed: true,
                        detail: String(localized: "CrossOver is activated."),
                        diagnostic: "valid license in \(label)"
                    )
                }

                let trouble = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trouble.isEmpty {
                    if trouble.localizedCaseInsensitiveContains("unable to load key") {
                        return Status(
                            licensed: false,
                            detail: notActivated,
                            diagnostic: "the verification key in the CrossOver bundle could not be read"
                        )
                    }
                    unchecked = "the license in \(label) could not be checked"
                }
            }

            rejection = unchecked
                ?? "no signature beside the license in \(label) verified against this bundle"
        }

        return Status(
            licensed: false,
            detail: notActivated,
            diagnostic: rejection ?? "no CrossOver license file found"
        )
    }

    @discardableResult
    static func requireValid(for install: CrossOverInstall) throws -> Status {
        let status = check(crossOverRoot: install.crossOverRoot)
        guard status.licensed else {
            throw StepFailure(
                step: String(localized: "Verify CrossOver license"),
                detail: status.detail
            )
        }
        return status
    }

    private static func sidecars(in dir: URL) -> [(path: String, digest: String)] {
        let candidates: [(path: String, digest: String)] = [
            (dir.appending(path: "\(licenseBase).sha256").path(percentEncoded: false), "-sha256"),
            (dir.appending(path: "\(licenseBase).sig").path(percentEncoded: false), "-sha1"),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
