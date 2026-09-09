import Foundation
import Testing

@testable import Semper

@Suite("Display diagnostic report mapping")
struct DisplayDiagnosticsReportMappingTests {
    @Test("Unverified writes are retained without control values")
    func unverifiedWriteIssue() throws {
        let identity = DisplayIdentity(
            vendorID: 5_555,
            productID: 6_666,
            serialNumber: 7_777_777
        )!
        let controls = DisplayControlInventory(
            brightness: .available(DisplayFeatureReading(current: 37, maximum: 113)!),
            contrast: .available(DisplayFeatureReading(current: 41, maximum: 127)!),
            volume: .available(DisplayVolumeReading(
                current: 53,
                maximum: 131,
                encoding: .continuous
            )!),
            input: .available(DisplayInputReading(
                current: 0x11,
                advertisedValues: [0x0F, 0x11]
            )!)
        )
        let item = inventoryItem(
            systemDisplay: .matched(88_888_888),
            controls: controls,
            identity: identity,
            registryID: 9_876_543_210,
            unverifiedWrites: [.input]
        )

        let report = makeReport(for: item)
        let display = try #require(report.displays.first)

        #expect(display.issues.contains(.controlWriteUnverified))
        let data = try DisplayDiagnosticsExporter.encodedData(for: report)
        #expect(data.range(of: Data("unverifiedWrites".utf8)) == nil)
        #expect(data.range(of: Data("\"input\"".utf8)) == nil)
        #expect(data.range(of: Data("Private monitor name".utf8)) == nil)
        #expect(data.range(of: Data("9876543210".utf8)) == nil)
        #expect(data.range(of: Data("7777777".utf8)) == nil)
        #expect(data.range(of: Data("88888888".utf8)) == nil)
        #expect(data.range(of: Data("\"current\"".utf8)) == nil)
        #expect(data.range(of: Data("\"maximum\"".utf8)) == nil)
        #expect(data.range(of: Data("\"advertisedValues\"".utf8)) == nil)
    }

    @Test("Availability reasons map to privacy-safe report states")
    func availabilityMapping() throws {
        let controls = DisplayControlInventory(
            brightness: .unavailable(.missingRegistryEndpoint),
            contrast: .unavailable(.invalidLiveValue(.contrast)),
            volume: .unavailable(.notAdvertised(.volume)),
            input: .unavailable(.unsupportedInputTable)
        )
        let item = inventoryItem(
            backend: .macOSSettings,
            systemDisplay: .unavailable(.ambiguousSystemDisplayMatch),
            controls: controls
        )

        let display = try #require(makeReport(for: item).displays.first)
        let states = Dictionary(uniqueKeysWithValues: display.controls.map { ($0.kind, $0.state) })

        #expect(display.backend == .macOSSettings)
        #expect(display.screenMapping == .ambiguous)
        #expect(states[.brightness] == .unavailable)
        #expect(states[.contrast] == .readFailed)
        #expect(states[.volume] == .unsupported)
        #expect(states[.inputSelection] == .unsupported)
        #expect(display.issues.contains(.missingRegistryEndpoint))
        #expect(display.issues.contains(.invalidControlValue))
        #expect(display.issues.contains(.controlNotAdvertised))
        #expect(display.issues.contains(.inputTableUnsupported))
        #expect(display.issues.contains(.ambiguousScreenMatch))
    }

    private func makeReport(for item: DisplayInventoryItem) -> DisplayDiagnosticsReport {
        DisplayDiagnosticsReport.make(
            for: item,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            applicationVersion: .init(major: 1, minor: 2, patch: 3),
            operatingSystemVersion: .init(major: 15, minor: 4),
            distribution: .direct
        )
    }

    private func inventoryItem(
        backend: DisplayControlBackend = .ddcCI,
        systemDisplay: DisplaySystemDisplayMatch = .matched(1),
        controls: DisplayControlInventory,
        identity: DisplayIdentity? = nil,
        registryID: UInt64? = nil,
        unverifiedWrites: Set<DisplayControlKind> = []
    ) -> DisplayInventoryItem {
        DisplayInventoryItem(
            id: .discovered(0),
            name: "Private monitor name",
            backend: backend,
            identity: identity,
            registryID: registryID,
            systemDisplay: systemDisplay,
            controls: controls,
            unverifiedWrites: unverifiedWrites
        )
    }
}
