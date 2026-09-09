import Foundation
import Testing
@testable import Semper

@MainActor
@Suite("Native scene intent runtime", .serialized)
struct NativeSceneIntentTests {
    @Test("Scene query exposes saved scenes and filters by name")
    func queryExposesAndFiltersScenes() async throws {
        let officeID = UUID()
        let focusID = UUID()
        let commands = IntentSceneCommands(scenes: [
            SceneCommandDescriptor(id: officeID, name: "Office"),
            SceneCommandDescriptor(id: focusID, name: "Deep Focus"),
        ])
        SemperSceneAppIntentRuntime.install(commands)
        let query = SemperSceneQuery()

        let suggested = try await query.suggestedEntities()
        let filtered = try await query.entities(matching: "focus")

        #expect(suggested.map(\.id) == [officeID, focusID])
        #expect(filtered.map(\.id) == [focusID])
    }

    @Test("Scene intent runtime forwards apply and restore")
    func runtimeForwardsCommands() async throws {
        let sceneID = UUID()
        let commands = IntentSceneCommands(scenes: [
            SceneCommandDescriptor(id: sceneID, name: "Office"),
        ])
        SemperSceneAppIntentRuntime.install(commands)

        let applyResult = try await SemperSceneAppIntentRuntime.applyScene(id: sceneID)
        let restoreResult = try await SemperSceneAppIntentRuntime.restoreScene()

        #expect(commands.appliedIDs == [sceneID])
        #expect(commands.restoreCount == 1)
        #expect(applyResult.message == "Applied Office")
        #expect(restoreResult.message == "Restored")
    }
}

@MainActor
private final class IntentSceneCommands: SceneCommandHandling {
    private let descriptors: [SceneCommandDescriptor]
    var appliedIDs: [UUID] = []
    var restoreCount = 0

    init(scenes: [SceneCommandDescriptor]) {
        self.descriptors = scenes
    }

    func availableScenes() -> [SceneCommandDescriptor] {
        descriptors
    }

    func applyScene(id: UUID) async throws -> SceneCommandExecution {
        appliedIDs.append(id)
        let name = descriptors.first(where: { $0.id == id })?.name ?? "Unknown"
        return SceneCommandExecution(message: "Applied \(name)")
    }

    func restoreScene() async throws -> SceneCommandExecution {
        restoreCount += 1
        return SceneCommandExecution(message: "Restored")
    }
}
