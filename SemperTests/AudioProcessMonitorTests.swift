import Testing
@testable import Semper

@Suite("Audio process monitor")
struct AudioProcessMonitorTests {
    @Test("Semper product bundle IDs are excluded from tap targets")
    func excludesSemperBundleIdentifiers() {
        #expect(AudioProcessMonitor.isSemperBundleIdentifier("systems.semper.Semper"))
        #expect(AudioProcessMonitor.isSemperBundleIdentifier("systems.semper.Semper.Debug"))
        #expect(!AudioProcessMonitor.isSemperBundleIdentifier("systems.semper.SemperHelper"))
        #expect(!AudioProcessMonitor.isSemperBundleIdentifier("com.apple.Safari"))
        #expect(!AudioProcessMonitor.isSemperBundleIdentifier(nil))
    }
}
