@MainActor
final class AppUpdater {
    // An upstream update would replace this fork's experimental changes.
    func check() {
        AppLog.note("updates: disabled in the trial-testing fork; rebuild from its source")
    }
}
