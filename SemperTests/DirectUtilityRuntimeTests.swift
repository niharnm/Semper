import AppKit
import Foundation
import KeyboardShortcuts
import Testing

@testable import Semper

@MainActor
@Suite("Direct utility runtime", .serialized)
struct DirectUtilityRuntimeTests {
    @Test("Away admission prevents service creation and direct lifecycle changes")
    func exclusiveRuntimeAdmission() async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.workspace)
            let workspace = try #require(runtime.workspace)
            let permit = try runtime.mutationAdmission.acquire(owner: .awayMode, mode: .exclusive)
            await #expect(throws: UtilityLifecycleError.self) { try await runtime.start(.sound) }
            await #expect(throws: UtilityLifecycleError.self) { try await runtime.start(.awake) }
            await #expect(throws: UtilityLifecycleError.self) { try await runtime.pause(.workspace) }
            await #expect(throws: UtilityLifecycleError.self) { try await runtime.remove(.workspace) }
            #expect(probe.creations[.sound] == nil)
            #expect(probe.creations[.awake] == nil)
            #expect(runtime.workspace === workspace)
            #expect(workspace.isRunning)
            #expect(await runtime.commands.execute(.init(rawValue: WorkspaceCommand.preview.rawValue))
                == .unavailable("End Away before changing other utilities."))
            #expect(runtime.mutationAdmission.release(permit))
            try await runtime.pause(.workspace)
            #expect(!workspace.isRunning)
        }
    }

    @Test("Reserved Workspace removal retains the service and its recovery receipt")
    func reservedWorkspaceRemoval() async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.workspace)
            let service = try #require(runtime.workspace)
            service.selectedApplicationIDs = [probe.application.id]
            service.arrangementName = "Presentation layout"
            await service.capture()
            let displaced = CGRect(x: 250, y: 180, width: 350, height: 250)
            await probe.workspaceBackend.change(probe.windowID, frame: displaced)
            await service.makePreview()
            let plan = try service.makeRestorePlan(selectedSlotIDs: Set(service.preview.map(\.id)))
            let token = UUID()
            try service.reserveForPresentation(plan, token: token)
            let receipt = await service.apply(plan, ownerToken: token)
            #expect(receipt.needsRecovery)
            await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.remove(.workspace) }
            #expect(runtime.workspace === service)
            #expect(service.isRunning)
            #expect(runtime.registry.state(for: .workspace)?.presence == .added)
            #expect(await probe.workspaceBackend.shutdownCalls == 0)
            let restored = await service.reverse(receipt, ownerToken: token)
            #expect(!restored.needsRecovery)
            try service.releasePresentationReservation(token)
            try await runtime.remove(.workspace)
            #expect(runtime.workspace == nil)
            #expect(await probe.workspaceBackend.shutdownCalls == 1)
        }
    }

    @Test("Safe Eject receives the shared gate before direct or batch mutation")
    func storageUsesSharedAdmission() async throws {
        try await withRuntime { runtime, probe in
            let volume = SafeEjectVolume(
                id: .init(bsdName: "testdisk1", registryID: 1, volumeUUID: "test-volume",
                    mountURL: probe.directory.appendingPathComponent("TestVolume")),
                name: "Test volume", deviceID: .init(bsdName: "testdisk", registryID: 2),
                isInternal: false, isRemovable: true, isEjectable: true, isRoot: false)
            probe.storageBackend.volumes = [volume]
            try await runtime.start(.storage)
            let storage = try #require(runtime.storage)
            let confirmation = try storage.prepareBatch().get()
            #expect(confirmation.eligible == [volume])
            let permit = try runtime.mutationAdmission.acquire(owner: .awayMode, mode: .exclusive)
            #expect(await storage.eject(volume) == .refused(.operationInProgress))
            await #expect(throws: SafeEjectFailure.operationInProgress) {
                try await storage.ejectBatch(confirmationID: confirmation.id).get()
            }
            #expect(probe.storageBackend.unmountCalls == 0)
            #expect(runtime.mutationAdmission.release(permit))
        }
    }

    @Test("Reserved Workspace pause and termination remain incomplete until recovery finishes")
    func reservedWorkspaceShutdown() async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.workspace)
            let service = try #require(runtime.workspace)
            service.selectedApplicationIDs = [probe.application.id]
            service.arrangementName = "Presentation layout"
            await service.capture()
            await service.makePreview()
            let plan = try service.makeRestorePlan(selectedSlotIDs: Set(service.preview.map(\.id)))
            let token = UUID()
            try service.reserveForPresentation(plan, token: token)
            await #expect(throws: UtilityCleanupDeferral.self) { try await runtime.pause(.workspace) }
            #expect(runtime.workspace === service)
            #expect(service.isRunning)
            await runtime.shutdown()
            #expect(runtime.workspace === service)
            #expect(runtime.lifecycle.failures[.workspace] != nil)
            #expect(await probe.workspaceBackend.shutdownCalls == 0)
            try service.releasePresentationReservation(token)
            await runtime.shutdown()
            #expect(runtime.workspace == nil)
            #expect(runtime.lifecycle.failures[.workspace] == nil)
            #expect(await probe.workspaceBackend.shutdownCalls == 1)
        }
    }

    @Test("Explicit starts create direct services once; pause reuses them and removal releases them")
    func directLifecycles() async throws {
        try await withRuntime { runtime, probe in
            #expect(probe.creations.isEmpty)
            for module in [UtilityModuleID.workspace, .shelf, .storage] { try await runtime.start(module) }
            let workspace = try #require(runtime.workspace)
            let shelf = try #require(runtime.shelf)
            let storage = try #require(runtime.storage)
            #expect(await probe.workspaceBackend.permissionPrompts.isEmpty)
            #expect(runtime.registry.state(for: .workspace)?.permission == .notDetermined)
            #expect(runtime.registry.state(for: .shelf)?.permission == .notRequired)
            #expect(runtime.registry.state(for: .storage)?.permission == .notRequired)

            for module in [UtilityModuleID.workspace, .shelf, .storage] { try await runtime.pause(module) }
            #expect(!workspace.isRunning)
            #expect(!shelf.isRunning)
            #expect(storage.state == .paused)
            #expect(probe.storageBackend.drains == 1)
            for module in [UtilityModuleID.workspace, .shelf, .storage] {
                try runtime.registry.resume(module)
                try await runtime.start(module)
                #expect(probe.creations[module] == 1)
            }
            #expect(runtime.workspace === workspace)
            #expect(runtime.shelf === shelf)
            #expect(runtime.storage === storage)
            for module in [UtilityModuleID.workspace, .shelf, .storage] { try await runtime.remove(module) }
            #expect(runtime.workspace == nil)
            #expect(runtime.shelf == nil)
            #expect(runtime.storage == nil)
            #expect(await probe.workspaceBackend.shutdownCalls == 1)
            #expect(storage.state == .shutDown)
            #expect(probe.storageBackend.drains == 2)
            #expect(probe.creations[.sound] == nil)
        }
    }

    @Test("Workspace owner actions open details without permission and return observed undo results")
    func workspaceCommands() async throws {
        try await withRuntime { runtime, probe in
            let undo = UtilityActionID(rawValue: WorkspaceCommand.undo.rawValue)
            #expect(runtime.commands.disabledReason(for: undo) == "No workspace restore is available to undo.")
            var requestIDs = Set<UUID>()
            for (command, workflow) in [
                (WorkspaceCommand.capture, WorkspaceWorkflow.capture), (.preview, .preview),
                (.restore, .restore), (.restore, .restore),
            ] {
                #expect(await runtime.commands.execute(.init(rawValue: command.rawValue)) == .completed)
                #expect(runtime.destination == .module(.workspace))
                let request = try #require(runtime.workspaceWorkflowRequest)
                #expect(request.workflow == workflow)
                #expect(requestIDs.insert(request.id).inserted)
            }
            #expect(await probe.workspaceBackend.permissionPrompts.isEmpty)
            #expect(await probe.workspaceBackend.moves.isEmpty)
            let service = try #require(runtime.workspace)
            service.selectedApplicationIDs = [probe.application.id]
            service.arrangementName = "Test desk"
            await service.capture()
            let displaced = CGRect(x: 250, y: 180, width: 350, height: 250)
            await probe.workspaceBackend.change(probe.windowID, frame: displaced)
            #expect(await service.makePreview())
            let selected = service.selectedArrangementID
            let bindings = service.bindings
            service.arrangementName = "Unfinished draft"
            let prompts = await probe.workspaceBackend.permissionPrompts
            #expect(await runtime.commands.execute(.init(rawValue: WorkspaceCommand.restore.rawValue)) == .completed)
            let request = try #require(runtime.workspaceWorkflowRequest)
            #expect(requestIDs.insert(request.id).inserted)
            #expect(service.selectedArrangementID == selected)
            #expect(service.arrangementName == "Unfinished draft")
            #expect(service.selectedApplicationIDs == [probe.application.id])
            #expect(service.bindings == bindings)
            #expect(!service.canRestore)
            await service.restore()
            #expect(await probe.workspaceBackend.moves.isEmpty)
            #expect(await probe.workspaceBackend.permissionPrompts == prompts)
            #expect(await service.makePreview(requestID: request.id))
            await service.restore()
            #expect(service.canUndo)
            #expect(runtime.summary(for: .workspace) == "1 arrangement, undo available")
            #expect(await runtime.commands.execute(undo) == .completed)
            #expect(try await probe.workspaceBackend.current(probe.windowID)?.frame == displaced)
            #expect(runtime.message == service.results.map(\.message).joined(separator: "\n"))
            #expect(runtime.commands.disabledReason(for: undo) == "No workspace restore is available to undo.")
        }
    }

    @Test("Reserved and busy Workspace navigation preserves the accepted workflow")
    func workspaceNavigationAdmission() async throws {
        try await withRuntime { runtime, probe in
            #expect(await runtime.commands.execute(.init(rawValue: WorkspaceCommand.capture.rawValue)) == .completed)
            let accepted = try #require(runtime.workspaceWorkflowRequest)
            let service = try #require(runtime.workspace)
            service.selectedApplicationIDs = [probe.application.id]
            service.arrangementName = "Desk"
            await service.capture()
            #expect(await service.makePreview())
            let plan = try service.makeRestorePlan(selectedSlotIDs: Set(service.preview.map(\.id)))
            let token = UUID()
            try service.reserveForPresentation(plan, token: token)
            let prompts = await probe.workspaceBackend.permissionPrompts
            for command in [WorkspaceCommand.capture, .preview, .restore] {
                #expect(
                    await runtime.commands.execute(.init(rawValue: command.rawValue))
                        == .unavailable("Workspace Restore is reserved by Presentation."))
                #expect(runtime.workspaceWorkflowRequest == accepted)
            }
            #expect(await probe.workspaceBackend.permissionPrompts == prompts)
            #expect(await probe.workspaceBackend.moves.isEmpty)
            try service.releasePresentationReservation(token)

            await probe.workspaceBackend.setDelay(true)
            let preview = Task { await service.makePreview(requestID: accepted.id) }
            do {
                try await waitFor { service.isBusy }
                for command in [WorkspaceCommand.capture, .preview, .restore] {
                    #expect(
                        await runtime.commands.execute(.init(rawValue: command.rawValue))
                            == .unavailable("Workspace Restore is busy."))
                    #expect(runtime.workspaceWorkflowRequest == accepted)
                }
            } catch {
                preview.cancel()
                _ = await preview.value
                throw error
            }
            preview.cancel()
            _ = await preview.value
            await probe.workspaceBackend.setDelay(false)
            #expect(await probe.workspaceBackend.moves.isEmpty)
            #expect(await runtime.commands.execute(.init(rawValue: WorkspaceCommand.restore.rawValue)) == .completed)
            #expect(runtime.workspaceWorkflowRequest?.id != accepted.id)
        }
    }

    @Test("Workspace shortcut follows metadata without creating Sound or requesting Accessibility")
    func workspaceShortcutLifecycle() async throws {
        try await withShortcutDefaults {
            try await withRuntime { runtime, probe in
                _ = NSApplication.shared
                try await runtime.remove(.workspace)
                runtime.startShellShortcuts()
                #expect(KeyboardShortcuts.getShortcut(for: UtilityRuntime.workspaceRestoreShortcut) == nil)
                let shortcut = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
                runtime.recordWorkspaceRestoreShortcut(shortcut)
                #expect(!KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                #expect(probe.creations.isEmpty)
                try runtime.registry.add(.workspace)
                try await waitFor { KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut) }
                #expect(probe.creations.isEmpty)
                #expect(await runtime.performWorkspaceRestoreShortcut() == .completed)
                let first = try #require(runtime.workspaceWorkflowRequest)
                #expect(first.workflow == .restore)
                #expect(await runtime.performWorkspaceRestoreShortcut() == .completed)
                #expect(runtime.workspaceWorkflowRequest?.id != first.id)
                #expect(await probe.workspaceBackend.permissionPrompts.isEmpty)
                #expect(await probe.workspaceBackend.moves.isEmpty)
                #expect(probe.creations == [.workspace: 1])
                try await runtime.pause(.workspace)
                #expect(!KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                #expect(await runtime.performWorkspaceRestoreShortcut() == .cancelled)
                try runtime.registry.resume(.workspace)
                try await waitFor { KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut) }
                #expect(probe.creations == [.workspace: 1])
                try await runtime.remove(.workspace)
                #expect(!KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                #expect(
                    runtime.settings.appSettings.customShortcuts[ShortcutAction.restoreWorkspace.rawValue]
                        == ShortcutCodable.from(shortcut))
                try runtime.registry.add(.workspace)
                try await waitFor { KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut) }
                #expect(probe.creations == [.workspace: 1])
                let queued = Task { await runtime.performWorkspaceRestoreShortcut() }
                await runtime.shutdown()
                #expect(await queued.value == .cancelled)
                #expect(await runtime.performWorkspaceRestoreShortcut() == .cancelled)
                #expect(!KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                #expect(probe.creations == [.workspace: 1])
            }
        }
    }

    @Test("Workspace recorder rejects Sound and Search conflicts without disabling the incumbent")
    func workspaceShortcutConflicts() async throws {
        try await withShortcutDefaults {
            try await withRuntime { runtime, probe in
                _ = NSApplication.shared
                runtime.startShellShortcuts()
                let original = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
                runtime.recordWorkspaceRestoreShortcut(original)
                let sound = ShortcutAction.targetAppMuteToggle
                let chord = KeyboardShortcuts.Shortcut(.m, modifiers: [.control, .option])
                runtime.settings.appSettings.customShortcuts[sound.rawValue] = ShortcutCodable.from(chord)
                KeyboardShortcuts.setShortcut(chord, for: sound.keyboardShortcutName)
                KeyboardShortcuts.onKeyDown(for: sound.keyboardShortcutName) {}
                defer { KeyboardShortcuts.removeHandler(for: sound.keyboardShortcutName) }
                for (conflict, reason) in [
                    (chord, "Already used by App Mute."),
                    (
                        try #require(KeyboardShortcuts.getShortcut(for: UtilityRuntime.searchShortcut)),
                        "Already used by Search Semper."
                    ),
                ] {
                    KeyboardShortcuts.setShortcut(conflict, for: UtilityRuntime.workspaceRestoreShortcut)
                    runtime.recordWorkspaceRestoreShortcut(conflict)
                    #expect(runtime.workspaceShortcutConflict == reason)
                    #expect(
                        runtime.settings.appSettings.customShortcuts[ShortcutAction.restoreWorkspace.rawValue]
                            == ShortcutCodable.from(original))
                    #expect(KeyboardShortcuts.getShortcut(for: UtilityRuntime.workspaceRestoreShortcut) == original)
                    #expect(KeyboardShortcuts.isEnabled(for: sound.keyboardShortcutName))
                    #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.searchShortcut))
                }
                #expect(probe.creations.isEmpty)
                let permit = try runtime.mutationAdmission.acquire(owner: .awayMode, mode: .exclusive)
                #expect(
                    await runtime.performWorkspaceRestoreShortcut()
                        == .unavailable("End Away before changing other utilities."))
                #expect(runtime.message == "End Away before changing other utilities.")
                #expect(probe.creations.isEmpty)
                #expect(runtime.mutationAdmission.release(permit))
            }
        }
    }

    @Test("Workspace shortcut reports service startup failures without constructing Sound")
    func workspaceShortcutFailure() async throws {
        try await withShortcutDefaults {
            try await withRuntime { runtime, probe in
                _ = NSApplication.shared
                probe.workspaceCreationFails = true
                runtime.startShellShortcuts()
                runtime.recordWorkspaceRestoreShortcut(.init(.r, modifiers: [.control, .option]))
                #expect(await runtime.performWorkspaceRestoreShortcut() == .failed("Fixture Workspace failure"))
                #expect(runtime.message == "Fixture Workspace failure")
                #expect(runtime.workspaceWorkflowRequest == nil)
                #expect(probe.creations == [.workspace: 1])
                #expect(await probe.workspaceBackend.permissionPrompts.isEmpty)
                #expect(await probe.workspaceBackend.moves.isEmpty)
            }
        }
    }

    @Test("Pausing Workspace drains a shortcut already waiting for startup")
    func workspaceShortcutDrain() async throws {
        try await withShortcutDefaults {
            try await withRuntime { runtime, probe in
                _ = NSApplication.shared
                let backend = DirectRuntimeHeldWorkspaceBackend()
                probe.workspaceBackendOverride = backend
                runtime.startShellShortcuts()
                runtime.recordWorkspaceRestoreShortcut(.init(.r, modifiers: [.control, .option]))
                let invocation = Task { await runtime.performWorkspaceRestoreShortcut() }
                do { try await waitFor { await backend.waiting } } catch {
                    await backend.release()
                    _ = await invocation.value
                    throw error
                }
                var paused = false
                let pause = Task {
                    try await runtime.pause(.workspace)
                    paused = true
                }
                do {
                    try await waitFor { !KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut) }
                    #expect(!paused)
                    #expect(runtime.workspaceWorkflowRequest == nil)
                } catch {
                    await backend.release()
                    _ = await invocation.value
                    _ = await pause.result
                    throw error
                }
                await backend.release()
                #expect(await invocation.value == .cancelled)
                try await pause.value
                #expect(paused)
                #expect(runtime.workspaceWorkflowRequest == nil)
                #expect(runtime.commands.running.isEmpty)
                #expect(probe.creations == [.workspace: 1])
            }
        }
    }

    @Test("Changing Search to the Workspace chord disables the conflict and preserves Search")
    func changingSearchResynchronizesWorkspace() async throws {
        try await withShortcutDefaults {
            try await withRuntime { runtime, probe in
                _ = NSApplication.shared
                runtime.startShellShortcuts()
                let chord = KeyboardShortcuts.Shortcut(.r, modifiers: [.control, .option])
                runtime.recordWorkspaceRestoreShortcut(chord)
                #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                KeyboardShortcuts.setShortcut(chord, for: UtilityRuntime.searchShortcut)
                runtime.recordSearchShortcut(chord)
                #expect(runtime.workspaceShortcutConflict == "Already used by Search Semper.")
                #expect(KeyboardShortcuts.getShortcut(for: UtilityRuntime.workspaceRestoreShortcut) == nil)
                #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.searchShortcut))
                #expect(await runtime.performWorkspaceRestoreShortcut() == .cancelled)
                let search = KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option])
                KeyboardShortcuts.setShortcut(search, for: UtilityRuntime.searchShortcut)
                runtime.recordSearchShortcut(search)
                #expect(runtime.workspaceShortcutConflict == nil)
                #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.workspaceRestoreShortcut))
                #expect(KeyboardShortcuts.isEnabled(for: UtilityRuntime.searchShortcut))
                #expect(probe.creations.isEmpty)
            }
        }
    }

    @Test("Shelf clear requires confirmation and only removes shelf-held items")
    func shelfClear() async throws {
        try await withRuntime { runtime, probe in
            let clear = UtilityActionID(rawValue: ShelfCommand.clear.rawValue)
            #expect(
                await runtime.commands.execute(clear)
                    == .confirmationRequired("Remove all shelf-held items? Source files remain untouched."))
            #expect(runtime.shelf == nil)
            #expect(await runtime.commands.execute(.init(rawValue: ShelfCommand.open.rawValue)) == .completed)
            let service = try #require(runtime.shelf)
            let source = probe.directory.appendingPathComponent("source.txt")
            try Data("keep this file".utf8).write(to: source)
            try service.addFile(source)
            #expect(runtime.summary(for: .shelf) == "1 item on the shelf")
            #expect(await runtime.commands.execute(clear, confirmed: true) == .completed)
            #expect(service.items.isEmpty)
            #expect(try String(contentsOf: source, encoding: .utf8) == "keep this file")
        }
    }

    @Test("Direct service changes update permission and limitation badges without restarting services")
    func liveStatus() async throws {
        try await withRuntime { runtime, probe in
            for module in [UtilityModuleID.workspace, .shelf, .storage] { try await runtime.start(module) }
            let workspace = try #require(runtime.workspace)
            workspace.selectedApplicationIDs = [probe.application.id]
            workspace.arrangementName = "Desk"
            await workspace.capture()
            await advanceTasks()
            #expect(runtime.registry.state(for: .workspace)?.permission == .granted)
            await probe.workspaceBackend.setPermission(false)
            await workspace.makePreview()
            await advanceTasks()
            #expect(runtime.registry.state(for: .workspace)?.permission == .revoked)
            #expect(
                runtime.registry.state(for: .workspace)?.runtime
                    == .limited(reason: WorkspaceError.permission.localizedDescription))

            let shelf = try #require(runtime.shelf)
            shelf.report(ShelfFailure.invalidStore)
            probe.storageBackend.inventoryFails = true
            probe.storageBackend.send(.volumesChanged)
            await advanceTasks()
            #expect(
                runtime.registry.state(for: .shelf)?.runtime
                    == .limited(reason: ShelfFailure.invalidStore.localizedDescription))
            #expect(
                runtime.registry.state(for: .storage)?.runtime == .limited(reason: SafeEjectFailure.unavailable.message)
            )
            #expect(runtime.summary(for: .storage) == "0 volumes, 1 issue")
            shelf.dismissMessage()
            probe.storageBackend.inventoryFails = false
            probe.storageBackend.send(.volumesChanged)
            await advanceTasks()
            #expect(runtime.registry.state(for: .shelf)?.runtime == .ready)
            #expect(runtime.registry.state(for: .storage)?.runtime == .ready)
            try await runtime.pause(.shelf)
            shelf.report(ShelfFailure.invalidStore)
            await advanceTasks()
            #expect(runtime.registry.state(for: .shelf)?.runtime == .paused)
            #expect(probe.creations == [.workspace: 1, .shelf: 1, .storage: 1])
        }
    }

    @Test("Manual Awake pause and removal preserve the canonical service and foreign lease")
    func awakeLeaseOwnership() async throws {
        try await withRuntime { runtime, probe in
            let service = try runtime.ensureAwakeService()
            #expect(runtime.registry.state(for: .awake)?.runtime == .stopped)
            let lease = try service.acquireLease(owner: .scene, keepsDisplayAwake: false)
            try await runtime.start(.awake)
            service.start(.untilTurnedOff)
            await advanceTasks()
            #expect(runtime.registry.state(for: .awake)?.runtime == .active)
            #expect(probe.powerBackend.active.count == 2)
            try await runtime.pause(.awake)
            #expect(runtime.awake === service)
            #expect(!service.isActive)
            #expect(service.hasLease(for: .scene))
            #expect(probe.powerBackend.active.count == 1)
            try runtime.registry.resume(.awake)
            try await runtime.start(.awake)
            #expect(runtime.awake === service)
            try await runtime.remove(.awake)
            #expect(runtime.awake === service)
            #expect(service.releaseLease(lease))
            await runtime.shutdown()
            #expect(runtime.awake == nil)
            #expect(probe.powerBackend.active.isEmpty)
            #expect(probe.creations[.awake] == 1)
            #expect(throws: UtilityLifecycleError.self) { try runtime.ensureAwakeService() }
            #expect(await runtime.commands.execute(.init(rawValue: WorkspaceCommand.preview.rawValue))
                == .unavailable("Semper is shutting down. Finish any pending recovery before quitting."))
        }
    }

    @Test("Awake cleanup retry retains the original service without reviving a terminated session", arguments: [false, true])
    func awakeCleanupRetry(terminating: Bool) async throws {
        try await withRuntime { runtime, probe in
            try await runtime.start(.awake)
            let service = try #require(runtime.awake)
            service.start(.oneHour)
            probe.powerBackend.rejectsRelease = true
            if terminating {
                await runtime.shutdown()
            } else {
                await #expect(throws: UtilityLifecycleError.self) { try await runtime.pause(.awake) }
            }
            #expect(runtime.awake === service)
            #expect(service.hasPendingAssertionCleanup)
            #expect(probe.powerBackend.active.count == 1)
            #expect(runtime.lifecycle.failures[.awake] != nil)
            #expect(probe.creations[.awake] == 1)

            probe.powerBackend.rejectsRelease = false
            if terminating { await runtime.shutdown() } else { try await runtime.pause(.awake) }
            #expect(runtime.awake == nil)
            #expect(probe.powerBackend.active.isEmpty)
            #expect(runtime.lifecycle.failures[.awake] == nil)
            #expect(probe.creations[.awake] == 1)
            service.start(.oneHour)
            #expect(!service.isActive)
            #expect(probe.powerBackend.active.isEmpty)
        }
    }

    private func withShortcutDefaults(_ body: () async throws -> Void) async throws {
        let names = ShortcutAction.allCases.map(\.keyboardShortcutName) + [UtilityRuntime.searchShortcut]
        let saved = names.map { name in
            (
                name, UserDefaults.standard.object(forKey: "KeyboardShortcuts_" + name.rawValue),
                KeyboardShortcuts.getShortcut(for: name), KeyboardShortcuts.isEnabled(for: name)
            )
        }
        defer {
            for (name, object, shortcut, _) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
                if let object {
                    UserDefaults.standard.set(object, forKey: "KeyboardShortcuts_" + name.rawValue)
                } else {
                    UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_" + name.rawValue)
                }
            }
            for (name, _, _, enabled) in saved {
                if enabled { KeyboardShortcuts.enable(name) } else { KeyboardShortcuts.disable(name) }
            }
        }
        for name in names { KeyboardShortcuts.setShortcut(nil, for: name) }
        KeyboardShortcuts.setShortcut(.init(.k, modifiers: [.command, .option]), for: UtilityRuntime.searchShortcut)
        try await body()
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition(), "Expected state was not observed within two seconds")
    }

    private func withRuntime(_ body: (UtilityRuntime, DirectRuntimeProbe) async throws -> Void) async throws {
        let suite = "DirectUtilityRuntimeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(
            ["sound", "awake", "workspace", "shelf", "storage"], forKey: ModuleRegistry.PersistenceKey.addedModules)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = DirectRuntimeProbe(directory: directory)
        let settings = SettingsManager(
            directory: directory.appendingPathComponent("Settings"), managesLaunchAtLogin: false)
        defer {
            settings.flushSync()
            defaults.removePersistentDomain(forName: suite)
            do { try FileManager.default.removeItem(at: directory) } catch {
                Issue.record(error, "Could not remove direct utility test files")
            }
        }
        let runtime = try UtilityRuntime(
            settings: settings, defaults: defaults,
            updateManager: UpdateManager(bundle: Bundle(for: NSObject.self), userDefaults: defaults),
            soundFactory: { _, _ in
                probe.creations[.sound, default: 0] += 1
                throw CancellationError()
            },
            awakeFactory: probe.makeAwake, workspaceFactory: probe.makeWorkspace,
            shelfFactory: probe.makeShelf, storageFactory: probe.makeStorage)
        do {
            try await body(runtime, probe)
            await runtime.shutdown()
        } catch {
            await runtime.shutdown()
            throw error
        }
        #expect(probe.creations[.sound] == nil)
        #expect(runtime.workspace == nil && runtime.shelf == nil && runtime.storage == nil)
    }

    private func advanceTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class DirectRuntimeProbe {
    let directory: URL
    let application: WorkspaceApplication
    let windowID: WorkspaceWindowID
    let workspaceBackend: WorkspaceTestBackend
    let storageBackend = DirectRuntimeStorageBackend()
    let powerBackend = DirectRuntimePowerBackend()
    var creations: [UtilityModuleID: Int] = [:]
    var workspaceCreationFails = false
    var workspaceBackendOverride: (any WorkspaceWindowBackend)?

    init(directory: URL) {
        self.directory = directory
        application = WorkspaceApplication(pid: 901, bundleID: "test.runtime", name: "Test", launchDate: .distantPast)
        windowID = WorkspaceWindowID(application: application, token: UUID())
        workspaceBackend = WorkspaceTestBackend(
            apps: [application],
            screens: [
                .init(id: "screen", name: "Test display", visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800))
            ],
            windows: [
                .init(
                    id: windowID, application: application, ordinal: 1,
                    frame: CGRect(x: 100, y: 100, width: 400, height: 300), issue: nil)
            ])
    }

    func makeAwake() -> AwakeService {
        creations[.awake, default: 0] += 1
        return AwakeService(
            backend: powerBackend, scheduler: DirectRuntimeExpiryScheduler(),
            workspaceNotificationCenter: NotificationCenter())
    }

    func makeWorkspace() throws -> WorkspaceService {
        creations[.workspace, default: 0] += 1
        if workspaceCreationFails { throw UtilityLifecycleError.unavailable("Fixture Workspace failure") }
        return WorkspaceService(
            backend: workspaceBackendOverride ?? workspaceBackend,
            store: WorkspaceStore(url: directory.appendingPathComponent("arrangements.json"))
        )
    }

    func makeShelf() -> ShelfService {
        creations[.shelf, default: 0] += 1
        return ShelfService(
            store: ShelfStore(root: directory.appendingPathComponent("Shelf")), access: DirectRuntimeFileAccess())
    }

    func makeStorage() -> SafeEjectService {
        creations[.storage, default: 0] += 1
        return SafeEjectService(backend: storageBackend)
    }
}

@MainActor
private final class DirectRuntimeStorageBackend: SafeEjectBackend {
    var inventoryFails = false
    var volumes: [SafeEjectVolume] = []
    private(set) var unmountCalls = 0
    private(set) var drains = 0
    private var handler: (@MainActor (SafeEjectSystemEvent) -> Void)?
    func start(onEvent: @escaping @MainActor (SafeEjectSystemEvent) -> Void) throws { handler = onEvent }
    func stop() { handler = nil }
    func drain() async -> Result<Void, SafeEjectFailure> {
        drains += 1
        return .success(())
    }
    func cancelPendingOperation() {}
    func inventory() throws -> SafeEjectInventory {
        if inventoryFails { throw SafeEjectFailure.unavailable }
        return .init(volumes: volumes, hasUnidentifiedLocalVolumes: false)
    }
    func unmount(_ volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        unmountCalls += 1
        return .failure(.unsupported)
    }
    func ejectDevice(containing volume: SafeEjectVolume) async -> Result<Void, SafeEjectFailure> {
        .failure(.unsupported)
    }
    func devicePresence(_ id: SafeEjectDeviceID) -> SafeEjectDevicePresence { .absent }
    func send(_ event: SafeEjectSystemEvent) { handler?(event) }
}

@MainActor
private final class DirectRuntimePowerBackend: PowerAssertionCreating {
    private var nextID: PowerAssertionID = 1
    var rejectsRelease = false
    private(set) var active: Set<PowerAssertionID> = []
    func createAssertion(kind: PowerAssertionKind, reason: String, timeout: TimeInterval?) throws(PowerAssertionError)
        -> PowerAssertionID
    {
        let id = nextID
        nextID += 1
        active.insert(id)
        return id
    }
    func releaseAssertion(_ id: PowerAssertionID) throws(PowerAssertionError) {
        if rejectsRelease { throw .releaseFailed(-1) }
        active.remove(id)
    }
}

@MainActor
private final class DirectRuntimeExpiryScheduler: AwakeExpiryScheduling {
    func scheduleExpiry(at date: Date, handler: @escaping @MainActor @Sendable () -> Void) {}
    func cancelScheduledExpiry() {}
}

private struct DirectRuntimeFileAccess: ShelfFileAccess {
    func begin(_ url: URL) -> Bool { false }
    func end(_ url: URL) {}
    func state(of url: URL) -> ShelfFileState { .available(isDirectory: false) }
    func bookmark(for url: URL) throws -> Data { throw ShelfFailure.unsupported }
    func resolve(_ bookmark: Data) throws -> URL { throw ShelfFailure.unsupported }
}

private actor DirectRuntimeHeldWorkspaceBackend: WorkspaceWindowBackend {
    private(set) var waiting = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    func applications() async -> [WorkspaceApplication] {
        waiting = true
        if !released { await withCheckedContinuation { waiter = $0 } }
        return []
    }
    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
    func permission(prompt: Bool) -> Bool {
        Issue.record("Navigation must not request Accessibility")
        return false
    }
    func displays() -> [WorkspaceDisplay] { [] }
    func windows(in applications: [WorkspaceApplication]) -> [WorkspaceWindowSnapshot] { [] }
    func current(_ id: WorkspaceWindowID) -> WorkspaceWindowSnapshot? { nil }
    func move(_ id: WorkspaceWindowID, to frame: CGRect, expected: CGRect) throws -> WorkspaceMoveObservation {
        Issue.record("Navigation must not move windows")
        throw WorkspaceError.permission
    }
    func shutdown() {}
}
