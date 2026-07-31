// Semper/Utilities/UpdateManager.swift
import Foundation
import Combine
import Sparkle

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
    @Published var updateChannel: UpdateChannel {
        didSet {
            userDefaults.set(updateChannel.rawValue, forKey: Self.updateChannelDefaultsKey)
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
        isConfigured = feedURL?.isEmpty == false && publicKey?.isEmpty == false
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
