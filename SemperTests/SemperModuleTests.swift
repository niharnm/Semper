import Foundation
import Testing
@testable import Semper

@Suite("SemperModule identifiers")
struct SemperModuleTests {

    @Test("Raw identifiers are stable")
    func stableIdentifiers() {
        #expect(SemperModule.sound.id == "sound")
        #expect(SemperModule.awake.id == "awake")
    }

    @Test("Module order lists Sound first")
    func moduleOrder() {
        #expect(SemperModule.allCases == [.sound, .awake])
    }

    @Test("The popup opens on Sound")
    func initialModule() {
        #expect(SemperModule.initial == .sound)
    }

    @Test("Every module has a name and symbol")
    func metadata() {
        for module in SemperModule.allCases {
            #expect(!module.displayName.isEmpty)
            #expect(!module.symbolName.isEmpty)
        }
    }
}
