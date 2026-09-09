#if DEBUG
    import AppKit
    import Foundation
    import SwiftUI

    @MainActor
    final class AwayShellUITestFixture {
        let coordinator: AwayModeCoordinator
        let settingsDirectory: URL

        private let support: AwayUITestSupport
        private let settings: SettingsManager
        private let drainCoordinator: @MainActor (AwayModeCoordinator) async -> AwayModeCleanupResult
        private var cleanupTask: Task<[String], Never>?
        private var shutdownStarted = false
        private var cleanupCompleted = false
        private var hostShown = false

        convenience init(options: AwayUITestLaunchOptions) throws {
            try self.init(options: options, temporaryDirectory: FileManager.default.temporaryDirectory)
        }

        init(
            options: AwayUITestLaunchOptions,
            temporaryDirectory: URL,
            persistenceWriter: SettingsPersistenceWriter = SettingsPersistenceWriter(),
            drainCoordinator: @escaping @MainActor (AwayModeCoordinator) async -> AwayModeCleanupResult = {
                await $0.shutdownAndDrain()
            }
        ) throws {
            let support = AwayUITestSupport(options: options, temporaryDirectory: temporaryDirectory)
            do {
                try FileManager.default.createDirectory(
                    at: support.settingsDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                support.cleanUp()
                throw error
            }
            let settings = SettingsManager(
                directory: support.settingsDirectory, managesLaunchAtLogin: false,
                persistenceWriter: persistenceWriter)
            support.prepare(settings)
            let coordinator = support.makeCoordinator(settings: settings, mutationAdmission: MutationAdmissionGate())
            coordinator.makeCurtainContent = { [weak coordinator] screen, isPrimary in
                guard let coordinator else { throw AwayWindowFailure.contentCreationFailed }
                return NSHostingView(
                    rootView: AwayCurtainView(coordinator: coordinator, screen: screen, isPrimary: isPrimary))
            }
            self.support = support
            self.settings = settings
            self.settingsDirectory = support.settingsDirectory
            self.coordinator = coordinator
            self.drainCoordinator = drainCoordinator
        }

        func showHostWindow() {
            guard !shutdownStarted, !hostShown else { return }
            hostShown = true
            support.showHostWindow(coordinator: coordinator)
        }

        func shutdownAndDrain() async -> [String] {
            shutdownStarted = true
            if cleanupCompleted { return [] }
            if let cleanupTask { return await cleanupTask.value }
            let task = Task { @MainActor in
                defer { self.cleanupTask = nil }
                switch await self.drainCoordinator(self.coordinator) {
                case .complete:
                    break
                case .ownedWorkPending:
                    return ["Away UI test work is still stopping. Retry cleanup."]
                case .powerAssertionPending:
                    return ["Away UI test power cleanup is still pending. Retry cleanup."]
                case .mutationAdmissionPending:
                    return ["Away UI test mutation ownership is still retained. Retry cleanup."]
                }
                guard self.settings.flushSync() else {
                    return ["Away UI test settings could not be saved. Temporary resources were retained for retry."]
                }
                self.support.cleanUp()
                do {
                    _ = try FileManager.default.attributesOfItem(atPath: self.settingsDirectory.path)
                    return ["Temporary Away UI test files could not be removed. Retry cleanup."]
                } catch let error as NSError
                    where error.domain == NSCocoaErrorDomain
                    && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
                {
                    self.cleanupCompleted = true
                    return []
                } catch {
                    return ["Temporary Away UI test file cleanup could not be verified. Retry cleanup."]
                }
            }
            cleanupTask = task
            return await task.value
        }
    }
#endif
