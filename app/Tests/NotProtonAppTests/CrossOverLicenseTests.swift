import Foundation
import Testing

@testable import NotProtonApp

// The check gates whether a runner may be cloned, so a wrong unlicensed verdict strands a user
// who holds a good license. Fixtures carry their own keypair, so it reads the same either way.
@Suite("CrossOver license")
struct CrossOverLicenseTests {

    // The tree hangs off a bundle so the layout check() is handed directly and the one
    // requireValid derives from a bundle are the same tree.
    private struct Fixture {
        let dir: URL
        let bundle: URL
        let local: URL
        let system: URL
        let key: URL

        var root: URL { SupportPaths.crossOverRoot(inBundle: bundle) }
        var publishedKey: URL { root.appending(path: "share/crossover/data/tie.pub") }
        var searchDirs: [URL] { [local, system] }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    private static let base = "com.codeweavers.CrossOver"

    private static let body = """
        [crossmac]
        customer=Test
        expires=2999/01/01
        [license]
        id=test

        """

    private static func fixture(withKey: Bool = true) throws -> Fixture {
        let fm = FileManager.default
        let dir = URL.temporaryDirectory.appending(path: "np-license-\(UUID().uuidString)")
        let fix = Fixture(
            dir: dir,
            bundle: dir.appending(path: "CrossOver.app"),
            local: dir.appending(path: "local"),
            system: dir.appending(path: "system"),
            key: dir.appending(path: "private.pem")
        )

        // The caller registers teardown on what it is handed, so a fixture that throws
        // half built has to take its own tree with it.
        do {
            for made in [
                fix.publishedKey.deletingLastPathComponent(), fix.local, fix.system,
            ] {
                try fm.createDirectory(at: made, withIntermediateDirectories: true)
            }
            try generate(key: fix.key, publishing: withKey ? fix.publishedKey : nil)
        } catch {
            fix.remove()
            throw error
        }
        return fix
    }

    // check, not run: openssl failing here leaves the fixture without the file the test
    // is about, and a test that then passes proves nothing.
    private static func generate(key: URL, publishing pub: URL?) throws {
        try Shell.check(
            CrossOverLicense.defaultOpenssl,
            ["genrsa", "-out", key.path(percentEncoded: false), "2048"]
        )
        guard let pub else { return }
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "rsa", "-in", key.path(percentEncoded: false),
            "-pubout", "-out", pub.path(percentEncoded: false),
        ])
    }

    @discardableResult
    private static func writeLicense(in dir: URL) throws -> URL {
        let license = dir.appending(path: "\(base).license")
        try body.write(to: license, atomically: true, encoding: .utf8)
        return license
    }

    private static func sign(
        _ license: URL, with key: URL, digest: String, sidecar: String
    ) throws {
        try Shell.check(CrossOverLicense.defaultOpenssl, [
            "dgst", digest, "-sign", key.path(percentEncoded: false),
            "-out", license.deletingLastPathComponent()
                .appending(path: "\(base).\(sidecar)").path(percentEncoded: false),
            license.path(percentEncoded: false),
        ])
    }

    @Test("A license signed by the bundle's key is accepted")
    func validLicenseIsAccepted() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs,
            trial: { _ in
                Issue.record("A verified paid license must not run the trial query.")
                return nil
            })
        #expect(status.licensed)
        #expect(status.trial == nil)
    }

    @Test("A verified active trial is accepted and carries its source into setup")
    func verifiedTrialIsAccepted() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let source = CrossOverTrial.Source(root: fix.root, bottle: "Steam")
        let status = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs,
            trial: { root in
                #expect(root == fix.root)
                return CrossOverTrial.Active(source: source, daysRemaining: 2)
            })
        #expect(status.licensed)
        #expect(status.trial == source)
        #expect(status.diagnostic.contains("active CrossOver trial"))
    }

    @Test("An expired or unverifiable trial cannot satisfy the license gate")
    func unverifiedTrialIsRefused() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let expired = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs,
            trial: { _ in
                CrossOverTrial.Active(
                    source: .init(root: fix.root, bottle: "Steam"), daysRemaining: 0)
            })
        #expect(!expired.licensed)
        #expect(expired.trial == nil)
        let failed = CrossOverLicense.check(
            crossOverRoot: fix.root, searchDirs: fix.searchDirs,
            trial: { _ in
                throw StepFailure(step: CrossOverTrial.step, detail: "simulated trial failure")
            })
        #expect(!failed.licensed)
        #expect(failed.trial == nil)
        #expect(failed.detail == CrossOverTrial.unavailableAdvice)
        #expect(failed.diagnostic.contains("simulated trial failure"))
    }

    @Test("A bundle carrying no verification key is named in the diagnostic")
    func missingKeyIsNamed() throws {
        let fix = try Self.fixture(withKey: false)
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "no verification key in the CrossOver bundle")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Both read the same to the user, so the log is the only thing left that can tell an
    // install that never had a license from one whose license was refused.
    @Test("No license file reads apart from a license that fails")
    func absentLicenseReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }

        let absent = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!absent.licensed)
        #expect(absent.diagnostic == "no CrossOver license file found")
        #expect(absent.detail == CrossOverLicense.notActivated)

        let license = try Self.writeLicense(in: fix.local)
        let other = fix.local.appending(path: "other.pem")
        try Self.generate(key: other, publishing: nil)
        try Self.sign(license, with: other, digest: "-sha256", sidecar: "sha256")

        let wrong = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!wrong.licensed)
        #expect(wrong.diagnostic.contains("verified against this bundle"))
        #expect(wrong.diagnostic != absent.diagnostic)
        #expect(wrong.detail == CrossOverLicense.notActivated)
    }

    @Test("A license with no signature beside it is named as such")
    func unsignedLicenseIsNamed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        try Self.writeLicense(in: fix.local)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("has no signature beside it"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The sidecar that verifies is not always the first one present, and taking only
    // the first turned a good license into an invalid one.
    @Test("A stale .sha256 does not condemn a license the .sig verifies")
    func staleSidecarDoesNotCondemnTheLicense() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha1", sidecar: "sig")
        try Data(repeating: 0x41, count: 256).write(
            to: fix.local.appending(path: "\(Self.base).sha256")
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
    }

    @Test("A license kept only in the system directory is found")
    func systemDirectoryIsSearched() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.system)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(status.licensed)
        #expect(status.diagnostic.contains(fix.system.path(percentEncoded: false)))
    }

    // Without the tool there is no verdict, and the user is told the same thing either way, so
    // the log is the only place a missing openssl reads apart from a CrossOver never activated.
    @Test("A missing openssl reads apart from an unactivated CrossOver in the log")
    func missingToolIsNotReportedAsUnlicensed() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")

        let status = CrossOverLicense.check(
            crossOverRoot: fix.root,
            searchDirs: fix.searchDirs,
            openssl: "/usr/bin/notproton-no-such-openssl"
        )
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not run"))
        #expect(status.diagnostic.contains("notproton-no-such-openssl"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // The reason reaches the user only through the thrown failure. requireValid searches the
    // machine's own directories, so only the two agreeing is fixed, not the text itself.
    @Test("The refusal carries the reason the check found and nothing else")
    func refusalCarriesTheReason() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let install = CrossOverInstall(
            bundle: fix.bundle, releaseVersion: nil, support: .unreadable
        )

        // A key generated for this fixture verifies no license on this machine, and a
        // machine with no license has nothing to find either.
        let expected = CrossOverLicense.check(crossOverRoot: install.crossOverRoot)
        #expect(!expected.licensed)

        do {
            try CrossOverLicense.requireValid(for: install)
            Issue.record("requireValid accepted a bundle whose key verifies nothing")
        } catch let failure as StepFailure {
            #expect(failure.detail == expected.detail)
        }
    }

    // An unreadable key exits the same status as a signature that does not match, which
    // leaves the log as the only place the two are told apart.
    @Test("An unreadable verification key reads apart from a license that fails in the log")
    func unreadableKeyReadsApartFromInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try Data("not a key".utf8).write(to: fix.publishedKey)

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic == "the verification key in the CrossOver bundle could not be read")
        #expect(status.detail == CrossOverLicense.notActivated)
    }

    // Same exit status again, and the license here is the one thing known to be good.
    @Test("A signature openssl cannot read is not called an invalid license")
    func unreadableSidecarIsNotCalledInvalid() throws {
        let fix = try Self.fixture()
        defer { fix.remove() }
        let license = try Self.writeLicense(in: fix.local)
        try Self.sign(license, with: fix.key, digest: "-sha256", sidecar: "sha256")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fix.local.appending(path: "\(Self.base).sha256")
                .path(percentEncoded: false)
        )

        let status = CrossOverLicense.check(crossOverRoot: fix.root, searchDirs: fix.searchDirs)
        #expect(!status.licensed)
        #expect(status.diagnostic.contains("could not be checked"))
        #expect(status.detail == CrossOverLicense.notActivated)
    }
}
