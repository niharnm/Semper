import Foundation
import Testing

@testable import Semper

@MainActor
@Suite("Paused utility actions")
struct PausedUtilityActionTests {
    @Test("Paused search and favorites expose the resume reason without running handlers")
    func pausedActionsStayVisibleAndDisabled() async throws {
        try await withCenter { center, descriptor in
            var availabilityChecks = 0
            var permissionRequests = 0
            var reason: String? = "Select a duration first."
            try center.register([
                UtilityActionHandler(
                    descriptor: descriptor,
                    disabledReason: {
                        availabilityChecks += 1
                        return reason
                    },
                    perform: { permissionRequests += 1 })
            ])
            try center.registry.setFavorite(true, for: descriptor.id)
            try center.registry.beginPause(.awake)
            try center.registry.completePause(.awake)

            #expect(center.registry.search("Awake timer") == [descriptor])
            #expect(center.registry.favoriteActions == [descriptor])
            #expect(center.disabledReason(for: descriptor.id) == "Resume this module in Modules first.")
            #expect(
                await center.execute(descriptor.id, confirmed: true)
                    == .unavailable("Resume this module in Modules first."))
            #expect(availabilityChecks == 0)
            #expect(permissionRequests == 0)
            #expect(center.running.isEmpty)
            #expect(center.registry.state(for: .awake)?.runtime == .paused)

            try center.registry.resume(.awake)
            #expect(center.registry.state(for: .awake)?.runtime == .stopped)
            #expect(center.registry.favoriteActions == [descriptor])
            #expect(center.disabledReason(for: descriptor.id) == reason)
            #expect(await center.execute(descriptor.id) == .unavailable("Select a duration first."))
            #expect(permissionRequests == 0)

            reason = nil
            #expect(await center.execute(descriptor.id) == .confirmationRequired("Start the timer?"))
            #expect(permissionRequests == 0)
            #expect(await center.execute(descriptor.id, confirmed: true) == .completed)
            #expect(permissionRequests == 1)
        }
    }

    @Test("Removing a paused module hides its actions, prunes favorites, and rejects execution")
    func removedPausedActionsStayUnavailable() async throws {
        try await withCenter { center, descriptor in
            var calls = 0
            try center.register([
                UtilityActionHandler(descriptor: descriptor, disabledReason: { nil }, perform: { calls += 1 })
            ])
            try center.registry.setFavorite(true, for: descriptor.id)
            try center.registry.beginPause(.awake)
            try center.registry.completePause(.awake)
            try center.registry.beginRemoval(.awake)
            #expect(center.registry.search("awake").isEmpty)
            #expect(center.registry.favoriteActions.isEmpty)
            try center.registry.completeRemoval(.awake)

            #expect(center.registry.search("awake").isEmpty)
            #expect(center.registry.favoriteIDs.isEmpty)
            #expect(center.registry.favoriteActions.isEmpty)
            #expect(center.registry.actionMetadata(for: descriptor.id) == descriptor)
            #expect(
                await center.execute(descriptor.id, confirmed: true)
                    == .unavailable("Add this module in Modules first."))
            #expect(calls == 0)
            #expect(center.running.isEmpty)
        }
    }

    private func withCenter(
        _ body: (UtilityCommandCenter, UtilityActionDescriptor) async throws -> Void
    ) async throws {
        let suite = "PausedUtilityActionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = try ModuleRegistry(defaults: defaults)
        let descriptor = UtilityActionDescriptor(
            id: UtilityActionID(rawValue: "awake.start"), module: .awake, title: "Start Awake",
            keywords: ["timer"], symbolName: "sun.max", confirmationMessage: "Start the timer?")
        try await body(UtilityCommandCenter(registry: registry), descriptor)
    }
}
