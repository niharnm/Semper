import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Native intent activation", .serialized)
struct NativeAppIntentActivationTests {
    @Test("Entity queries leave dormant Sound inactive")
    func queriesDoNotActivate() {
        let owner = NSObject()
        var activations = 0
        SemperAppIntentRuntime.installActivation(owner: owner) { activations += 1 }
        defer { SemperAppIntentRuntime.uninstallActivation(owner: owner) }
        _ = SemperAppIntentRuntime.applications()
        _ = SemperAppIntentRuntime.outputs()
        #expect(activations == 0)
    }

    @Test("Explicit intent execution awaits module activation and preserves rejection")
    func executionActivates() async {
        let owner = NSObject()
        var activations = 0
        var executions = 0
        SemperAppIntentRuntime.installActivation(owner: owner) {
            activations += 1
            await Task.yield()
            throw ActivationFailure.denied
        }
        defer { SemperAppIntentRuntime.uninstallActivation(owner: owner) }
        await #expect(throws: ActivationFailure.denied) {
            try await SemperAppIntentRuntime.perform { _ in
                executions += 1
                return .init(status: .applied, message: "Applied")
            }
        }
        #expect(activations == 1)
        #expect(executions == 0)
    }

    @Test("An old runtime cannot remove a replacement activation handler")
    func replacementOwnership() async {
        let old = NSObject()
        let current = NSObject()
        SemperAppIntentRuntime.installActivation(owner: old) { throw ActivationFailure.oldOwner }
        SemperAppIntentRuntime.installActivation(owner: current) { throw ActivationFailure.denied }
        defer { SemperAppIntentRuntime.uninstallActivation(owner: current) }
        SemperAppIntentRuntime.uninstallActivation(owner: old)
        await #expect(throws: ActivationFailure.denied) {
            try await SemperAppIntentRuntime.perform { _ in .init(status: .applied, message: "Applied") }
        }
    }

    @Test("A cancelled intent does not activate Sound")
    func cancellationBeforeActivation() async {
        let owner = NSObject()
        var activations = 0
        SemperAppIntentRuntime.installActivation(owner: owner) { activations += 1 }
        defer { SemperAppIntentRuntime.uninstallActivation(owner: owner) }
        let task = Task {
            try await SemperAppIntentRuntime.perform { _ in .init(status: .applied, message: "Applied") }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(activations == 0)
    }
}

private enum ActivationFailure: Error, Equatable {
    case denied, oldOwner
}
