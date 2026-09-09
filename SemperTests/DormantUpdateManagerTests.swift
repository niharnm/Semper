#if DEBUG
    import Foundation
    import Testing

    @testable import Semper

    @MainActor
    @Suite("Dormant update manager")
    struct DormantUpdateManagerTests {
        @Test("The dormant factory does not construct a Sparkle controller")
        func constructionStaysDormant() throws {
            try withDefaults { defaults in
                let manager = UpdateManager.dormantForTesting(userDefaults: defaults)
                #expect(!manager.hasUpdaterControllerForTesting)
                #expect(!manager.isConfigured)
                #expect(!manager.canCheckForUpdates)
                #expect(!manager.automaticUpdatesEnabled)
                #expect(manager.lastUpdateCheckDate == nil)
                #expect(manager.updateChannel == .stable)
            }
        }

        @Test("Update actions and channel changes leave the dormant controller absent")
        func actionsStayDormant() throws {
            try withDefaults { defaults in
                let manager = UpdateManager.dormantForTesting(userDefaults: defaults)
                var deferralChecks = 0
                manager.shouldDeferRelaunch = {
                    deferralChecks += 1
                    return true
                }
                for channel in UpdateChannel.allCases {
                    manager.updateChannel = channel
                    manager.checkForUpdates()
                    manager.setAutomaticUpdatesEnabled(true)
                    manager.setAutomaticUpdatesEnabled(false)
                    manager.resumeDeferredInstallation()
                    #expect(!manager.hasUpdaterControllerForTesting)
                    #expect(!manager.isConfigured)
                    #expect(!manager.canCheckForUpdates)
                    #expect(!manager.automaticUpdatesEnabled)
                    #expect(manager.lastUpdateCheckDate == nil)
                }
                #expect(deferralChecks == 0)
            }
        }

        @Test("The dormant factory reads and writes only its supplied channel defaults")
        func usesSuppliedDefaults() throws {
            try withDefaults { first in
                try withDefaults { second in
                    let key = "Semper.updateChannel"
                    let standardBefore = UserDefaults.standard.string(forKey: key)
                    first.set("canary", forKey: key)
                    second.set("stable", forKey: key)
                    let manager = UpdateManager.dormantForTesting(userDefaults: first)
                    #expect(manager.updateChannel == .canary)
                    manager.updateChannel = .stable
                    #expect(first.string(forKey: key) == "stable")
                    manager.updateChannel = .canary
                    #expect(first.string(forKey: key) == "canary")
                    #expect(second.string(forKey: key) == "stable")
                    #expect(UserDefaults.standard.string(forKey: key) == standardBefore)
                    #expect(!manager.hasUpdaterControllerForTesting)
                }
            }
        }

        private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
            let suite = "DormantUpdateManagerTests.\(UUID())"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            try body(defaults)
        }
    }
#endif
