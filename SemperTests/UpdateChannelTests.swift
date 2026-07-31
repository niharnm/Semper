import Testing
@testable import Semper

@Suite("Update channel")
struct UpdateChannelTests {
    @Test("stable only receives default-channel releases")
    func stableChannel() {
        #expect(UpdateChannel.stable.allowedSparkleChannels.isEmpty)
    }

    @Test("canary receives stable and canary releases")
    func canaryChannel() {
        #expect(
            UpdateChannel.canary.allowedSparkleChannels
                == [UpdateChannel.sparkleCanaryChannel]
        )
    }

    @Test("a saved choice takes precedence over the build default")
    func savedChoiceWins() {
        #expect(
            UpdateChannel.resolved(storedValue: "stable", bundleDefault: "canary")
                == .stable
        )
    }

    @Test("a canary build defaults to canary without a saved choice")
    func canaryBuildDefault() {
        #expect(
            UpdateChannel.resolved(storedValue: nil, bundleDefault: "canary")
                == .canary
        )
    }

    @Test("invalid values fail closed to stable")
    func invalidValues() {
        #expect(
            UpdateChannel.resolved(storedValue: "preview", bundleDefault: "nightly")
                == .stable
        )
    }
}
