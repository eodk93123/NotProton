# CrossOver trial testing

The [`trial-testing` branch of eodk93123/NotProton](https://github.com/eodk93123/NotProton/tree/trial-testing) prepares a personal NotProton build for testing with an active CrossOver trial. It starts from upstream commit `4df944fd9d545de519f5766c63ec5249528d40e7` (November 2, 2026).

## Current status

This branch implements explicit opt-in trial validation. It checks the original CrossOver application's own trial status during setup and at each game or helper entry. The implementation is experimental: the actual vendor query and a game launch have not been tested on a Mac. See the validation requirements below before relying on the build.

The experimental app does not start Sparkle or check upstream releases, including when **Check for Updates…** is selected. That menu action records a message in the app log. Install later versions by rebuilding this branch. This prevents an upstream update from replacing the experimental changes.

## Test machine and supported versions

| Requirement | Expected configuration |
| --- | --- |
| Mac | Apple Silicon, macOS 15.0 or newer |
| CrossOver | **CrossOver 26.3** stable, installed normally and with an active trial |
| Steam | Native macOS Steam; this source revision lists stable build **1792618285** and beta build **1792626604** |
| Compatibility tool | Start with the CrossOver 26.3 Rosetta tool |
| Build machine | A supported Mac with full Xcode, or the existing GitHub Actions `app` workflow |

The version list comes from the [upstream README in this checkout](../README.md). It is specific to this source revision. A newer Steam or CrossOver build may need an upstream compatibility update; do not replace the supported-runner hashes to force an unknown build through. The project also supports specific CrossOver Preview builds, but this guide targets stable 26.3.

The app's deployment target is macOS 15.0. Compiling it requires newer developer tools: the package declares Swift tools 6.2, and the source uses SDK APIs introduced in macOS 26.1 with runtime availability checks. The existing CI selects Xcode 27.0. The functional Steam injection code is arm64; the x86_64 slice is only a stub.

## Get the testing branch

The fork is [eodk93123/NotProton](https://github.com/eodk93123/NotProton). Clone the published testing branch with:

```sh
git clone --branch trial-testing https://github.com/eodk93123/NotProton.git
cd NotProton
```

If you already have the prepared checkout, inspect its remotes and branch instead of cloning over it:

```sh
git remote -v
git branch --show-current
```

To publish later changes, commit them on `trial-testing` and confirm that `origin` points to `eodk93123/NotProton` before pushing:

```sh
git diff --check
git status --short
git push -u origin trial-testing
```

Every Actions command below names the fork explicitly because GitHub CLI can otherwise choose the upstream repository as its default. Run `gh auth status` first; use `gh auth login` if sign-in is needed.

To start a separate personal fork from upstream, use `gh repo fork NotProtonNot/NotProton --clone --remote`, create a testing branch, and apply the reviewed changes. A fresh upstream fork still contains upstream's trial restriction.

## Build with GitHub Actions

The existing [app workflow](../.github/workflows/app.yml) builds all components, stages the payload, packages the application, runs the C and Swift test suites, and uploads a `NotProton` artifact containing `NotProton.zip`. It does not need a CrossOver installation or a signing secret on the runner.

In your fork's **Actions** tab, enable workflows if GitHub asks. Then choose **app → Run workflow → trial-testing**. The command-line equivalent is:

```sh
gh workflow enable app.yml --repo eodk93123/NotProton
gh workflow run app.yml --repo eodk93123/NotProton --ref trial-testing
gh run list --repo eodk93123/NotProton --workflow app.yml --branch trial-testing
```

Copy the run ID for the commit you pushed. Replace `RUN_ID` below with that number:

```sh
gh run watch RUN_ID --repo eodk93123/NotProton --exit-status
gh run view RUN_ID --repo eodk93123/NotProton
gh run download RUN_ID --repo eodk93123/NotProton --name NotProton --dir out/ci-artifact
```

The `app` workflow runs automatically for pushes to `main` and pull requests. Pushing only to `trial-testing` requires the manual dispatch above. The existing `xcode-27` label is a [GitHub-hosted Apple Silicon runner](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/), so this build does not require a private runner.

Use the `app` workflow for this experiment. The separate `release` workflow publishes tags, releases, and a Sparkle appcast and requires a private signing key. A downloadable Actions artifact is sufficient for testing.

On the Mac, extract the inner app archive. If you downloaded the artifact through the browser, first extract GitHub's artifact archive to obtain that inner `NotProton.zip`:

```sh
ditto -x -k out/ci-artifact/NotProton.zip out/ci-app
codesign --verify --strict out/ci-app/NotProton.app
```

The app uses ad hoc signing, not a Developer ID notarization. Code-signature verification checks bundle integrity; it does not establish that trial handling or a game launch works. If macOS blocks the app, use its normal per-app **Open Anyway** approval after reviewing the build source.

## Build locally on a Mac

Work in a path without spaces; the font build rejects whitespace in its paths. Install full Xcode and select it before building. For a local installation named `Xcode.app`:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
xcodebuild -version
swift --version
xcrun --sdk macosx --show-sdk-version
```

Use Xcode 27.0 to match the current CI where practical. The macOS 15.0 runtime target does not mean the latest Xcode can be installed on every macOS 15 machine; CI can supply the build when local developer tools are too old.

Install the build dependencies with Homebrew, then create the pinned font-tool environment:

```sh
brew install cmake mingw-w64 bison flex fontforge gpatch python node
python3 -m venv scratch/fontvenv
scratch/fontvenv/bin/pip install 'afdko==4.0.3' 'fonttools==4.66.1'
export PATH="$PWD/scratch/fontvenv/bin:$PATH"
```

For the first build, fetch the same Dobby revision used by CI:

```sh
git clone --no-checkout https://github.com/jmpews/Dobby.git vendor/dobby
git -C vendor/dobby checkout 5dfc8546954ce3b3198132ab13fddb89ee92cdd7
```

If `vendor/dobby` already exists from a prior build, verify its revision with `git -C vendor/dobby rev-parse HEAD` rather than cloning over it.

Build in dependency order from the repository root:

```sh
make dobby
make all overlay-shim iconmaker appinfo
make bridge
make fonts
make app
make -s mincheck
make -s l10ncheck
make -s trialcheck
make -s app-tests
```

`make bridge` fetches the pinned Wine and Proton sources and builds both architecture variants. `make app` stages those components, creates `out/NotProton.app`, signs it ad hoc, and verifies its signature. Running `swift build` alone does not create the complete application payload. CrossOver is needed for the later runtime test, not for compiling the app.

To package the app after a successful build:

```sh
make app-zip
```

The resulting archive is `out/NotProton.zip`.

## Enable trial testing on the Mac

Move the rebuilt `NotProton.app` into a permanent writable folder, such as `~/Applications`, before opening it. NotProton records its executable location so Steam can open the prefix-rebuild helper later; a temporary or translocated app location cannot provide that reliably.

First open the original CrossOver 26.3 application and initialize its trial through the normal CrossOver interface. Create or select a real CrossOver bottle and launch a program in it through CrossOver. The bottle name used below must already exist in that original installation.

Quit NotProton, then enable the experiment with the exact bottle name. This example assumes that your existing bottle is named `Steam`:

```sh
defaults write com.notproton.NotProton crossOverTrialBottle -string "Steam"
```

Then deploy the rebuilt app into native macOS Steam:

1. Quit Steam and any running games or Wine tools, then open this rebuilt NotProton app.
2. Refresh **Status** and check the Steam location. Use **Choose…** if your native Steam app is somewhere else. The CrossOver 26.3 row should show the verified trial's remaining day count.
3. Choose **Setup → Install**. This deploys NotProton into Steam and downloads any missing Valve components. For a first installation with no existing runner, it also sets up the detected authorized CrossOver tool automatically.
4. Check the CrossOver 26.3 row. If it still offers **Set Up**, choose it. If that copy was set up by an earlier build, use its **Reinstall** action once to record the selected trial source and refresh its launch script.
5. Wait for installation to finish successfully, then start native macOS Steam again.

The trial check requires the vendor's `--demo-status` result to contain a strictly positive number of remaining days. An expired, missing, or unrecognized status blocks trial setup and launch. The fork does not initialize or reset the trial itself.

The runner's source marker records the original CrossOver runtime path and the selected bottle. Keep the original CrossOver application and that bottle installed at their original locations. Each game or helper entry queries the original vendor tool again; accepting an active trial once during setup is insufficient. The query stops after 30 seconds if the vendor tool does not return.

In the restarted Steam client, use **Settings → Compatibility** to select **CrossOver 26.3** (the Rosetta tool). For a particular game, select **Properties → Compatibility → Force the use of a specific Steam Play compatibility tool**, then select **CrossOver 26.3** there. A successful launch is still a manual test to record, not an outcome established by these instructions.

To stop opting into trial setup, quit NotProton and remove its preference:

```sh
defaults delete com.notproton.NotProton crossOverTrialBottle
```

This changes only NotProton's preference. It does not change CrossOver's trial or license state. Existing trial-created runners retain their recorded source and require a fresh trial check when launched.

## Validation still required

This branch was prepared in a Linux workspace without Xcode or a macOS runtime. No macOS application build, Swift test run, or real CrossOver trial/game launch has been completed there.

Before treating a candidate as ready, record:

1. The tested commit and a successful `app` workflow run, including Swift tests, minimum-version checks, and localization checks.
2. The Mac chip, macOS version, Steam build, and exact CrossOver version/build.
3. The trial state reported by the original CrossOver application before the test.
4. Whether runner setup and a representative game launch work, together with any failure message and **Setup → Reveal Log in Finder** output.
5. The behavior when the trial is absent, expired, or cannot be verified, and whether an existing paid installation still works.

The new `trialcheck` suite exercises the trial query and runner checks with a fake vendor wrapper. It covers rejection paths without touching a real CrossOver trial. The full CI workflow does not run Steam games. Passing those tests and the app build therefore leaves the actual vendor-query and game integration tests outstanding.

## Sources

- [Repository build targets](../Makefile) and [Swift package](../app/Package.swift).
- [Existing app workflow](../.github/workflows/app.yml) and [release workflow](../.github/workflows/release.yml).
- [GitHub CLI: create a fork](https://cli.github.com/manual/gh_repo_fork).
- [GitHub CLI: dispatch a workflow at a branch](https://cli.github.com/manual/gh_workflow_run).
- [GitHub CLI: download a run's artifact](https://cli.github.com/manual/gh_run_download).
- [GitHub's Xcode 27 runner announcement](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/).
