// Semper/Utilities/UpdateManager.swift
import Foundation
import Combine
import Sparkle

struct UpdaterConfiguration {
    static func isValid(feedURL: String?, publicKey: String?) -> Bool {
        guard
            let feedURL,
            let url = URL(string: feedURL),
            url.scheme == "https",
            url.host?.isEmpty == false,
            let publicKey,
            let keyData = Data(base64Encoded: publicKey),
            keyData.count == 32
        else {
            return false
        }
        return true
    }
}

struct AutomaticUpdateState {
    let checksForUpdates: Bool
    let downloadsUpdates: Bool

    init(checksForUpdates: Bool, downloadsUpdates: Bool) {
        self.checksForUpdates = checksForUpdates
        self.downloadsUpdates = downloadsUpdates
    }

    init(isEnabled: Bool) {
        checksForUpdates = isEnabled
        downloadsUpdates = isEnabled
    }

    var isEnabled: Bool {
        checksForUpdates && downloadsUpdates
    }
}

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case canary

    static let sparkleCanaryChannel = "canary"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .canary: "Canary"
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .stable: []
        case .canary: [Self.sparkleCanaryChannel]
        }
    }

    static func resolved(storedValue: String?, bundleDefault: String?) -> UpdateChannel {
        if let storedValue, let stored = UpdateChannel(rawValue: storedValue) {
            return stored
        }
        if let bundleDefault, let bundled = UpdateChannel(rawValue: bundleDefault) {
            return bundled
        }
        return .stable
    }
}

/// Manages app updates via Sparkle
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    private static let updateChannelDefaultsKey = "Semper.updateChannel"

    private var updaterController: SPUStandardUpdaterController!
    private let userDefaults: UserDefaults
    let isConfigured: Bool

    @Published var canCheckForUpdates = false
    @Published private(set) var automaticUpdatesEnabled = false
    @Published var updateChannel: UpdateChannel {
        didSet {
            userDefaults.set(updateChannel.rawValue, forKey: Self.updateChannelDefaultsKey)
            if isConfigured {
                updaterController?.updater.resetUpdateCycleAfterShortDelay()
            }
        }
    }

    override convenience init() {
        self.init(bundle: .main, userDefaults: .standard)
    }

    init(bundle: Bundle, userDefaults: UserDefaults) {
        let info = bundle.infoDictionary
        let feedURL = info?["SUFeedURL"] as? String
        let publicKey = info?["SUPublicEDKey"] as? String
        let bundleDefault = info?["SemperDefaultUpdateChannel"] as? String

        self.userDefaults = userDefaults
        isConfigured = UpdaterConfiguration.isValid(feedURL: feedURL, publicKey: publicKey)
        updateChannel = UpdateChannel.resolved(
            storedValue: userDefaults.string(forKey: Self.updateChannelDefaultsKey),
            bundleDefault: bundleDefault
        )

        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        if isConfigured {
            do {
                try updaterController.updater.start()
                updaterController.updater.publisher(for: \.canCheckForUpdates)
                    .receive(on: DispatchQueue.main)
                    .assign(to: &$canCheckForUpdates)
                Publishers.CombineLatest(
                    updaterController.updater.publisher(for: \.automaticallyChecksForUpdates),
                    updaterController.updater.publisher(for: \.automaticallyDownloadsUpdates)
                )
                .map { checksForUpdates, downloadsUpdates in
                    AutomaticUpdateState(
                        checksForUpdates: checksForUpdates,
                        downloadsUpdates: downloadsUpdates
                    ).isEnabled
                }
                .receive(on: DispatchQueue.main)
                .assign(to: &$automaticUpdatesEnabled)
            } catch {
                NSLog("Semper updater failed to start: %@", error.localizedDescription)
            }
        }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel.allowedSparkleChannels
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        updaterController.checkForUpdates(nil)
    }

    func setAutomaticUpdatesEnabled(_ isEnabled: Bool) {
        guard isConfigured else { return }
        let state = AutomaticUpdateState(isEnabled: isEnabled)
        updaterController.updater.automaticallyChecksForUpdates = state.checksForUpdates
        updaterController.updater.automaticallyDownloadsUpdates = state.downloadsUpdates
    }

    var lastUpdateCheckDate: Date? {
        isConfigured ? updaterController.updater.lastUpdateCheckDate : nil
    }
}
