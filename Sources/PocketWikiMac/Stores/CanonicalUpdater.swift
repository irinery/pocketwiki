import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CanonicalUpdater {
    private let service = CanonicalUpdateService()
    private var lastCheckAt: Date?

    private(set) var state: CanonicalUpdateState = .idle

    var availableRelease: CanonicalRelease? {
        switch state {
        case .available(let release),
             .downloading(let release),
             .installing(let release):
            release
        case .failed(let release, _):
            release
        default:
            nil
        }
    }

    func checkForUpdates(force: Bool = false) async {
        guard !state.isBusy else { return }
        if !force,
           let lastCheckAt,
           Date().timeIntervalSince(lastCheckAt) < 300 {
            return
        }

        state = .checking
        do {
            let bundle = Bundle.main
            let currentTag = bundle.object(forInfoDictionaryKey: "PocketWikiReleaseTag") as? String
            let currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let release = try await service.latestRelease(
                currentTag: currentTag,
                currentVersion: currentVersion
            )
            lastCheckAt = Date()
            state = release.map(CanonicalUpdateState.available) ?? .current
        } catch {
            state = .failed(nil, error.localizedDescription)
        }
    }

    func installAvailableUpdate() async {
        guard let release = availableRelease, !state.isBusy else { return }
        state = .downloading(release)
        do {
            try await service.install(release, replacing: Bundle.main.bundleURL)
            state = .installing(release)
            try? await Task.sleep(for: .milliseconds(250))
            NSApp.terminate(nil)
        } catch {
            state = .failed(release, error.localizedDescription)
        }
    }
}
