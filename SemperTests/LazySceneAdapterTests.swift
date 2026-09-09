import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Lazy scene adapters")
struct LazySceneAdapterTests {
    @Test("Construction does not resolve services and unprepared controls cannot mutate")
    func unpreparedDomain() async throws {
        var resolutions = 0
        let adapter = LazySceneAdapter(domain: .audio) {
            resolutions += 1
            return nil
        }
        #expect(resolutions == 0)
        #expect(await adapter.capability(for: .audioOutputDevice) == .unsupported)
        await #expect(throws: LazySceneAdapterError.unavailable(.audio)) {
            try await adapter.writeValue(.text("output"), for: .audioOutputDevice)
        }
        await #expect(throws: LazySceneAdapterError.unavailable(.audio)) {
            try await adapter.readValue(for: .audioOutputDevice)
        }
        #expect(resolutions == 3)
    }

    @Test("A domain never resolves a service for another domain's control")
    func domainIsolation() async {
        var resolutions = 0
        let adapter = LazySceneAdapter(domain: .audio) {
            resolutions += 1
            return nil
        }
        #expect(await adapter.capability(for: .awakeMode) == .unsupported)
        #expect(resolutions == 0)
    }

    @Test("Forwarding uses the current prepared adapter and releases access when it is removed")
    func replacementAndRemoval() async throws {
        let first = LazyAdapterProbe()
        let second = LazyAdapterProbe()
        let prepared = LazyAdapterBinding(adapter: first)
        let adapter = LazySceneAdapter(domain: .power) { prepared.adapter }
        #expect(await adapter.capability(for: .awakeMode) == .readWrite)
        #expect(await adapter.preflightTarget(.awake(.system), for: .awakeMode) == .ready)
        #expect(await adapter.prerequisites(of: .awake(.system), for: .awakeMode) == [.init(control: .awakeMode)])
        #expect(await adapter.restorationValue(for: .awake(.off), control: .awakeMode) == .awake(.off))
        try await adapter.writeValue(.awake(.system), for: .awakeMode)
        #expect(try await adapter.readValue(for: .awakeMode) == .awake(.system))
        prepared.adapter = second
        try await adapter.writeValue(.awake(.displayAndSystem), for: .awakeMode)
        #expect(first.value == .awake(.system))
        #expect(second.value == .awake(.displayAndSystem))
        prepared.adapter = nil
        #expect(await adapter.capability(for: .awakeMode) == .unsupported)
        await #expect(throws: LazySceneAdapterError.unavailable(.power)) {
            try await adapter.writeValue(.awake(.off), for: .awakeMode)
        }
        #expect(second.value == .awake(.displayAndSystem))
    }
}

@MainActor
private final class LazyAdapterBinding {
    var adapter: LazyAdapterProbe?
    init(adapter: LazyAdapterProbe) { self.adapter = adapter }
}

@MainActor
private final class LazyAdapterProbe: SceneControlAdapting {
    var value: SceneValue = .awake(.off)
    func capability(for control: SceneControl) async -> SceneControlCapability { .readWrite }
    func prerequisites(of value: SceneValue, for control: SceneControl) async -> [SceneControlPrerequisite] {
        [.init(control: control)]
    }
    func readValue(for control: SceneControl) async throws -> SceneValue { value }
    func writeValue(_ value: SceneValue, for control: SceneControl) async throws { self.value = value }
}
