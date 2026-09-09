import Foundation
import Testing

@testable import Semper

@Suite("Display diagnostic export")
struct DisplayDiagnosticsTests {
    typealias Report = DisplayDiagnosticsReport

    @Test("Encoding is byte-stable and round-trips")
    func deterministicEncoding() throws {
        let report = fixture()
        let first = try DisplayDiagnosticsExporter.encodedData(for: report)
        let second = try DisplayDiagnosticsExporter.encodedData(for: report)

        #expect(first == second)
        #expect(first.last == 0x0A)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Report.self, from: first) == report)
    }

    @Test("Report schema has no display identity or local path fields")
    func privacySchema() throws {
        let data = try DisplayDiagnosticsExporter.encodedData(for: fixture())
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(root.keys) == [
                "applicationVersion", "displays", "distribution", "generatedAt",
                "operatingSystemVersion", "schemaVersion",
            ])

        let displays = try #require(root["displays"] as? [[String: Any]])
        let display = try #require(displays.first)
        #expect(Set(display.keys) == ["backend", "connection", "controls", "issues", "screenMapping"])

        let controls = try #require(display["controls"] as? [[String: Any]])
        #expect(controls.allSatisfy { Set($0.keys) == ["kind", "state"] })

        let forbiddenKeys = ["displayID", "edid", "host", "id", "name", "path", "serialNumber", "user"]
        #expect(forbiddenKeys.allSatisfy { data.range(of: Data("\"\($0)\"".utf8)) == nil })
    }

    @Test("Controls and issues use canonical order")
    func canonicalOrdering() {
        let display = Report.Display(
            connection: .external,
            backend: .ddcCI,
            screenMapping: .matched,
            controls: [
                .init(kind: .volume, state: .readFailed),
                .init(kind: .brightness, state: .available),
                .init(kind: .contrast, state: .unsupported),
            ],
            issues: [.protocolVersionUnsupported, .capabilitiesUnavailable]
        )

        #expect(display.controls.map(\.kind) == [.brightness, .contrast, .volume])
        #expect(display.issues == [.capabilitiesUnavailable, .protocolVersionUnsupported])
    }

    @Test("Injected writer receives canonical bytes and chosen local URL")
    func injectedWriter() throws {
        var receivedData: Data?
        var receivedURL: URL?
        let exporter = DisplayDiagnosticsExporter { data, url in
            receivedData = data
            receivedURL = url
        }
        let report = fixture()
        let destination = URL(fileURLWithPath: "/tmp/semper-display-diagnostic.json")

        try exporter.export(report, to: destination)

        #expect(receivedData == (try DisplayDiagnosticsExporter.encodedData(for: report)))
        #expect(receivedURL == destination)
    }

    @Test("Non-file destinations are rejected before writing")
    func rejectsRemoteDestination() throws {
        var writes = 0
        let exporter = DisplayDiagnosticsExporter { _, _ in writes += 1 }
        let destination = try #require(URL(string: "https://example.com/display-diagnostic.json"))

        #expect(throws: DisplayDiagnosticsExporter.Failure.destinationMustBeLocalFile) {
            try exporter.export(fixture(), to: destination)
        }
        #expect(writes == 0)
    }

    @Test("Remote-host file URLs are rejected before writing")
    func rejectsRemoteFileHost() throws {
        var writes = 0
        let exporter = DisplayDiagnosticsExporter { _, _ in writes += 1 }
        let destination = try #require(URL(string: "file://example.com/tmp/display-diagnostic.json"))

        #expect(throws: DisplayDiagnosticsExporter.Failure.destinationMustBeLocalFile) {
            try exporter.export(fixture(), to: destination)
        }
        #expect(writes == 0)
    }

    private func fixture() -> Report {
        Report(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            applicationVersion: .init(major: 1, minor: 2, patch: 3),
            operatingSystemVersion: .init(major: 15, minor: 4),
            distribution: .direct,
            displays: [
                .init(
                    connection: .external,
                    backend: .ddcCI,
                    screenMapping: .matched,
                    controls: [
                        .init(kind: .inputSelection, state: .unsupported),
                        .init(kind: .brightness, state: .available),
                    ],
                    issues: [.inputTableUnsupported]
                )
            ]
        )
    }
}
