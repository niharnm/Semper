import Foundation
import Testing
@testable import Semper

@Suite("SemperModule identifiers")
struct SemperModuleTests {

    @Test("Raw identifiers are stable")
    func stableIdentifiers() {
        #expect(SemperModule.home.id == "home")
        #expect(SemperModule.sound.id == "sound")
        #expect(SemperModule.awake.id == "awake")
        #expect(SemperModule.displays.id == "displays")
        #expect(SemperModule.away.id == "away")
    }

    @Test("Module order starts with Home")
    func moduleOrder() {
        #expect(SemperModule.allCases == [.home, .sound, .awake, .displays, .away])
    }

    @Test("The popup opens on Home")
    func initialModule() {
        #expect(SemperModule.initial == .home)
    }

    @Test("Every module has a name and symbol")
    func metadata() {
        for module in SemperModule.allCases {
            #expect(!module.displayName.isEmpty)
            #expect(!module.symbolName.isEmpty)
        }
    }
}
