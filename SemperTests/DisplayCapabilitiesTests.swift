import Foundation
import Testing

@testable import Semper

@Suite("MCCS capability advertisements")
struct DisplayCapabilitiesTests {
    typealias Capabilities = DisplayCapabilities

    @Test("Balanced unrelated sections cannot contribute input features")
    func sectionsAndOrderedInputs() throws {
        let value = try Capabilities.parse(
            "(prot(monitor)model(Test (Display))cmds(60 62)"
                + "window1(vcp(60(03)))vcp(10 12 14(01 05) 60(11 0f 12) 62)mccs_ver(2.2))"
        ).get()
        #expect(value.protocolVersion == .init(major: 2, minor: 2))
        #expect(value.advertisedVCPFeatures == [0x10, 0x12, 0x14, 0x60, 0x62])
        #expect(value.advertisedInputValues == [0x11, 0x0F, 0x12])
        #expect(value.inputSelection == .success([0x11, 0x0F, 0x12]))
        #expect(value.volume == .success(.continuousSubrange))
    }

    @Test("Whitespace, case and one trailing NUL do not alter advertisements")
    func formatting() throws {
        let expected = try Capabilities.parse("(vcp(60(0A 11)62)mccs_ver(2.1))").get()
        let actual = try Capabilities.parse("\t( VCP ( 60 ( 0a\t11 ) 62 )\nMCCS_VER( 2.1 ) )\r\n\0")
            .get()
        #expect(actual == expected)
    }

    @Test("Packed hex bytes retain feature and value boundaries")
    func packedBytes() throws {
        let value = try Capabilities.parse("(vcp(101260(110F12)62F7(02FF))mccs_ver(2.2))").get()
        #expect(value.advertisedVCPFeatures == [0x10, 0x12, 0x60, 0x62, 0xF7])
        #expect(value.advertisedInputValues == [0x11, 0x0F, 0x12])
        #expect(value.volume == .success(.continuousSubrange))
        #expect(Capabilities.parse("(vcp((60)))") == .failure(.malformedVCPList))
    }

    @Test("Nonstandard advertised input bytes stay raw and are never assigned connector names")
    func vendorInputs() throws {
        let value = try Capabilities.parse("(mccs_ver(2.2)vcp(60(E0 1B 00 FF)))").get()
        #expect(value.advertisedInputValues == [0xE0, 0x1B, 0x00, 0xFF])
        #expect(value.inputSelection == .success([0xE0, 0x1B, 0x00, 0xFF]))
    }

    @Test(
        "Known protocol versions choose advertisement encoding only",
        arguments: ["2.0", "2.1", "2.2", "3.0"])
    func versionEncodings(_ version: String) throws {
        let value = try Capabilities.parse("(vcp(60(01 11)62)mccs_ver(\(version)))").get()
        #expect(
            value.volume
                == .success(version == "2.0" || version == "2.1" ? .continuous : .continuousSubrange))
        #expect(
            value.inputSelection
                == (version == "3.0" ? .failure(.unsupportedInputTable) : .success([0x01, 0x11])))
        #expect(value.advertisedInputValues == [0x01, 0x11])
    }

    @Test(
        "Future and older encodings remain unavailable",
        arguments: ["1.0", "2.3", "3.1", "4.0", "255.255", "0.0"])
    func unknownVersion(_ version: String) throws {
        let value = try Capabilities.parse("(vcp(60(11) 62)mccs_ver(\(version)))").get()
        let parsedVersion = try #require(value.protocolVersion)
        #expect(value.inputSelection == .failure(.unsupportedVersion(parsedVersion)))
        #expect(value.volume == .failure(.unsupportedVersion(parsedVersion)))
        #expect(value.advertisedInputValues == [0x11])
    }

    @Test("An absent version retains advertisements without inventing an encoding")
    func missingVersion() throws {
        let value = try Capabilities.parse("(vcp(60(01 11)62))").get()
        #expect(value.protocolVersion == nil)
        #expect(value.inputSelection == .failure(.missingVersion))
        #expect(value.volume == .failure(.missingVersion))
        #expect(value.advertisedVCPFeatures == [0x60, 0x62])
    }

    @Test("Absent sections and features have different reasons")
    func missingAdvertisements() throws {
        let absent = try Capabilities.parse("(model(vcp(60(11)))mccs_ver(2.2))").get()
        #expect(absent.inputSelection == .failure(.missingVCPSection))
        #expect(absent.volume == .failure(.missingVCPSection))
        #expect(absent.advertisedInputValues == nil)
        let empty = try Capabilities.parse("(vcp()mccs_ver(2.2))").get()
        #expect(empty.inputSelection == .failure(.notAdvertised))
        #expect(empty.volume == .failure(.notAdvertised))
        let other = try Capabilities.parse("(vcp(14(60 62))mccs_ver(2.2))").get()
        #expect(other.inputSelection == .failure(.notAdvertised))
        #expect(other.volume == .failure(.notAdvertised))
    }

    @Test("An advertised input feature needs its own nonempty value list")
    func missingInputValues() throws {
        let missing = try Capabilities.parse("(mccs_ver(2.2)vcp(60 62))").get()
        #expect(missing.advertisedInputValues == nil)
        #expect(missing.inputSelection == .failure(.inputValuesMissing))
        #expect(missing.volume == .success(.continuousSubrange))
        let empty = try Capabilities.parse("(mccs_ver(2.2)vcp(60()))").get()
        #expect(empty.advertisedInputValues == [])
        #expect(empty.inputSelection == .failure(.inputValuesEmpty))
    }

    @Test("A volume sublist is not a readback range")
    func volumeValuesDoNotSetRange() throws {
        let value = try Capabilities.parse("(mccs_ver(2.2)vcp(62(00 01)))").get()
        #expect(value.volume == .success(.continuousSubrange))
        #expect(value.inputSelection == .failure(.notAdvertised))
    }

    @Test(
        "Duplicate relevant sections are rejected even when identical",
        arguments: [
            "(vcp(60(11))vcp(60(11)))", "(mccs_ver(2.1)mccs_ver(2.1))",
            "(mccs_ver(2.1)MCCS_VER(3.0))", "(vcp()VCP(62))",
        ])
    func duplicateSections(_ raw: String) {
        #expect(Capabilities.parse(raw) == .failure(.duplicateSection))
    }

    @Test("Duplicate features and values cannot silently change the selection model")
    func duplicateEntries() {
        #expect(Capabilities.parse("(vcp(60(11)60(12)))") == .failure(.duplicateFeature(0x60)))
        #expect(
            Capabilities.parse("(vcp(60(11 11)))")
                == .failure(.duplicateValue(feature: 0x60, value: 0x11)))
        #expect(
            Capabilities.parse("(vcp(14(0a 0A)62))")
                == .failure(.duplicateValue(feature: 0x14, value: 0x0A)))
    }

    @Test(
        "Version text is strictly two decimal components",
        arguments: [
            "", "2", "2.", ".2", "2.2a", "2.2.0", "+2.1", "-1.0", "2 .1", "256.0", "2.256", "2.(1)",
        ])
    func malformedVersion(_ text: String) {
        #expect(Capabilities.parse("(vcp(60(11)62)mccs_ver(\(text)))") == .failure(.malformedVersion))
    }

    @Test(
        "Malformed VCP lists do not retain an earlier valid feature",
        arguments: [
            "60(1)", "60(0x11)", "60(+1)", "60(-1)", "60(G0)", "600", "60(010)",
            "60(11,12)", "60(11(12))", "60(11)(12)", "60 6", "60 0x62",
        ])
    func malformedHex(_ list: String) {
        #expect(Capabilities.parse("(vcp(10 \(list))mccs_ver(2.2))") == .failure(.malformedVCPList))
    }

    @Test(
        "Unbalanced, truncated and nonsection inputs fail",
        arguments: [
            "vcp(60(11))", "(", "(vcp(60(11))", "(vcp(60(11)", "(vcp)", "(vcp 60)",
            "((vcp(60)))", "(vcp(60)garbage)", "(vcp(62)model(unclosed)",
        ])
    func malformedStructure(_ raw: String) {
        #expect(Capabilities.parse(raw) == .failure(.malformedStructure))
    }

    @Test("Trailing content is not another advertisement", arguments: [")", "(vcp(60(11)))", "junk"])
    func trailingContent(_ suffix: String) {
        #expect(Capabilities.parse("(vcp(62)mccs_ver(2.2))\(suffix)") == .failure(.trailingData))
    }

    @Test("Empty input has an explicit reason", arguments: ["", " \t\r\n", "\0"])
    func empty(_ raw: String) {
        #expect(Capabilities.parse(raw) == .failure(.empty))
    }

    @Test(
        "Embedded NUL, controls and non-ASCII are rejected",
        arguments: [
            "(model(é)vcp(62))", "(vcp(60\0 62))", "(vcp(62))\0\0", "(vcp(62))\u{7F}", "(vcp(62))\u{1B}",
        ])
    func characters(_ raw: String) {
        #expect(Capabilities.parse(raw) == .failure(.invalidCharacter))
    }

    @Test("Size bound includes optional terminator")
    func byteLimit() throws {
        let raw = "(model(" + String(repeating: "A", count: Capabilities.maximumBytes - 9) + "))"
        #expect(raw.utf8.count == Capabilities.maximumBytes)
        _ = try Capabilities.parse(raw).get()
        #expect(Capabilities.parse(raw + "\0") == .failure(.inputTooLarge))
        #expect(
            Capabilities.parse(String(repeating: "A", count: 1_000_000)) == .failure(.inputTooLarge))
    }

    @Test("Nesting limit includes outer and section parentheses")
    func nestingLimit() throws {
        let accepted =
            "(model(" + String(repeating: "(", count: Capabilities.maximumNesting - 2)
            + "A" + String(repeating: ")", count: Capabilities.maximumNesting)
        _ = try Capabilities.parse(accepted).get()
        let rejected =
            "(model(" + String(repeating: "(", count: Capabilities.maximumNesting - 1)
            + "A" + String(repeating: ")", count: Capabilities.maximumNesting + 1)
        #expect(Capabilities.parse(rejected) == .failure(.nestingLimitExceeded))
    }

    @Test("Every section counts toward the bound, including unrelated sections")
    func sectionLimit() throws {
        let sections = String(repeating: "vendor()", count: Capabilities.maximumSections)
        _ = try Capabilities.parse("(\(sections))").get()
        #expect(Capabilities.parse("(\(sections)vendor())") == .failure(.sectionLimitExceeded))
    }

    @Test("Feature and value counts are bounded without truncation")
    func entryLimits() throws {
        let allBytes = (0...255).map { String(format: "%02X", $0) }.joined(separator: " ")
        let features = try Capabilities.parse("(vcp(\(allBytes))mccs_ver(2.2))").get()
        #expect(features.advertisedVCPFeatures.count == Capabilities.maximumFeatures)
        #expect(Capabilities.parse("(vcp(\(allBytes) 00))") == .failure(.featureLimitExceeded))
        let values = try Capabilities.parse("(vcp(60(\(allBytes)))mccs_ver(2.2))").get()
        #expect(values.advertisedInputValues?.count == Capabilities.maximumValuesPerFeature)
        #expect(Capabilities.parse("(vcp(60(\(allBytes) 00)))") == .failure(.valueLimitExceeded))
    }

    @Test("Every proper prefix of a complete advertisement fails")
    func truncationAtEveryByte() {
        let bytes = Array("(vcp(10 60(11 0F)62)mccs_ver(2.2))".utf8)
        for count in 0..<bytes.count {
            if case .success = Capabilities.parse(String(decoding: bytes.prefix(count), as: UTF8.self)) {
                Issue.record("Accepted a truncated advertisement at byte \(count)")
            }
        }
    }

    @Test("Parsing has no shared mutable state")
    func concurrentParsing() async {
        await withTaskGroup(of: Bool.self) { group in
            for value in 1...64 {
                group.addTask {
                    let hex = String(format: "%02X", value)
                    guard case .success(let result) = Capabilities.parse("(vcp(60(\(hex))62)mccs_ver(2.1))")
                    else { return false }
                    return result.advertisedInputValues == [UInt8(value)]
                        && result.volume == .success(.continuous)
                }
            }
            for await result in group { #expect(result) }
        }
    }
}
