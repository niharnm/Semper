// Semper/Utilities/UpdateManager.swift
import Foundation
import Combine
import Sparkle

/// Manages app updates via Sparkle
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    let isConfigured: Bool

    @Published var canCheckForUpdates = false

    override init() {
        let info = Bundle.main.infoDictionary
        let feedURL = info?["SUFeedURL"] as? String
        let publicKey = info?["SUPublicEDKey"] as? String
        isConfigured = feedURL?.isEmpty == false && publicKey?.isEmpty == false

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        if isConfigured {
            do {
                try updaterController.updater.start()
                updaterController.updater.publisher(for: \.canCheckForUpdates)
                    .receive(on: DispatchQueue.main)
                    .assign(to: &$canCheckForUpdates)
            } catch {
                NSLog("Semper updater failed to start: %@", error.localizedDescription)
            }
        }
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get {
            isConfigured && updaterController.updater.automaticallyChecksForUpdates
        }
        set {
            guard isConfigured else { return }
            updaterController.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get {
            isConfigured && updaterController.updater.automaticallyDownloadsUpdates
        }
        set {
            guard isConfigured else { return }
            updaterController.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    var lastUpdateCheckDate: Date? {
        isConfigured ? updaterController.updater.lastUpdateCheckDate : nil
    }
}
