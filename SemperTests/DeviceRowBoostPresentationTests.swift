import Testing
@testable import Semper

@Suite("Device row boost presentation")
struct DeviceRowBoostPresentationTests {
    @Test("An unverified output never shows a boost range")
    func unverifiedOutputHidesBoost() {
        let capabilities = OutputDeviceCapabilities(
            maximumGain: 3,
            supportsBalance: true,
            channelCount: 2,
            isRouteVerified: false,
            unavailableReason: "Route an app here to verify boost"
        )

        #expect(!DeviceRow.supportsBoost(
            capabilities: capabilities,
            maximumSelectableGain: 3
        ))
        #expect(DeviceRow.controlMaximumGain(
            capabilities: capabilities,
            maximumSelectableGain: 3
        ) == 1)
        #expect(DeviceRow.maximumSelectablePercentage(
            capabilities: capabilities,
            maximumSelectableGain: 3
        ) == 100)
    }

    @Test("Copy uses the verified output's supplied maximum")
    func copyUsesSuppliedMaximum() {
        let capabilities = OutputDeviceCapabilities(
            maximumGain: 2.25,
            supportsBalance: true,
            channelCount: 2,
            isRouteVerified: true,
            unavailableReason: nil
        )

        #expect(DeviceRow.masterVolumeHelp(
            deviceName: "Studio Display",
            capabilities: capabilities,
            maximumSelectableGain: 3
        ) == "Master volume for Studio Display, maximum 225 percent")
        #expect(DeviceRow.idleMasterStatus(
            capabilities: capabilities,
            maximumSelectableGain: 3
        ) == "Software gain up to 225% · -1 dB limiter")

        let lowerSelectableMaximum = OutputDeviceCapabilities(
            maximumGain: 3,
            supportsBalance: true,
            channelCount: 2,
            isRouteVerified: true,
            unavailableReason: nil
        )
        #expect(DeviceRow.controlMaximumGain(
            capabilities: lowerSelectableMaximum,
            maximumSelectableGain: 2.25
        ) == 2.25)
        #expect(DeviceRow.masterVolumeHelp(
            deviceName: "Studio Display",
            capabilities: lowerSelectableMaximum,
            maximumSelectableGain: 2.25
        ) == "Master volume for Studio Display, maximum 225 percent")
    }

    @Test("A volume limit disables boost and reports the enforced maximum")
    func volumeLimitDisablesBoost() {
        let capabilities = OutputDeviceCapabilities(
            maximumGain: 3,
            supportsBalance: true,
            channelCount: 2,
            isRouteVerified: true,
            unavailableReason: nil
        )

        #expect(!DeviceRow.supportsBoost(
            capabilities: capabilities,
            maximumSelectableGain: 0.8
        ))
        #expect(DeviceRow.controlMaximumGain(
            capabilities: capabilities,
            maximumSelectableGain: 0.8
        ) == 0.8)
        #expect(DeviceRow.sliderToVolume(
            1,
            backend: .hardware,
            maximumGain: 0.8
        ) == 0.8)
        #expect(DeviceRow.maximumSelectablePercentage(
            capabilities: capabilities,
            maximumSelectableGain: 0.8
        ) == 80)
        #expect(DeviceRow.idleMasterStatus(
            capabilities: capabilities,
            maximumSelectableGain: 0.8
        ) == "80% volume limit · boost unavailable")
    }

    @Test("An observed value above the limit remains visible")
    func observedValueAboveLimit() {
        #expect(!DeviceRow.isObservedAboveMaximum(
            nil,
            maximumSelectableGain: 0.4
        ))
        #expect(DeviceRow.isObservedAboveMaximum(
            0.8,
            maximumSelectableGain: 0.4
        ))
        #expect(DeviceRow.outputPercentage(
            for: 0.8,
            backend: .hardware
        ) == 80)
        #expect(DeviceRow.outputPercentage(
            for: 0.8,
            backend: .software
        ) == 89)
    }

    @Test("Numeric entry converts the enforced maximum without view state")
    func numericEntryConvertsMaximum() {
        let commit = DeviceRow.percentageCommit(
            50,
            backend: .hardware,
            maximumGain: 0.5
        )

        #expect(commit.sliderFraction == 1)
        #expect(commit.volume == 0.5)
    }

    @Test("Invalid capability values fail closed")
    func invalidValuesFailClosed() {
        let capabilities = OutputDeviceCapabilities(
            maximumGain: .infinity,
            supportsBalance: true,
            channelCount: 2,
            isRouteVerified: true,
            unavailableReason: nil
        )

        #expect(!DeviceRow.supportsBoost(
            capabilities: capabilities,
            maximumSelectableGain: .nan
        ))
        #expect(DeviceRow.maximumSelectablePercentage(
            capabilities: capabilities,
            maximumSelectableGain: .nan
        ) == 100)
    }
}
