extension UtilityModuleDescriptor {
    static let integratedCatalog: [Self] = catalog.map { descriptor in
        switch descriptor.id {
        case .workspace:
            return .init(
                id: .workspace,
                title: WorkspaceModuleMetadata.name,
                summary: WorkspaceModuleMetadata.purpose,
                symbolName: WorkspaceModuleMetadata.symbol,
                disclosure: .init(
                    permissionReasons: [
                        .init(name: "Accessibility", reason: WorkspaceModuleMetadata.permissionReason)
                    ],
                    runningBackgroundPolicy: WorkspaceModuleMetadata.backgroundWork,
                    localDataPolicy: WorkspaceModuleMetadata.localDataPolicy,
                    requiredModules: WorkspaceModuleMetadata.dependencies.compactMap(UtilityModuleID.init(rawValue:)),
                    conflicts: WorkspaceModuleMetadata.conflicts,
                    settingsSchemaVersion: WorkspaceModuleMetadata.settingsSchemaVersion,
                    minimumOS: WorkspaceModuleMetadata.minimumOS
                )
            )
        case .shelf:
            let metadata = ShelfModuleRegistration()
            return .init(
                id: .shelf,
                title: metadata.title,
                summary: metadata.purpose,
                symbolName: metadata.symbol,
                disclosure: .init(
                    permissionReasons: metadata.permissions.map { .init(name: "File access", reason: $0) },
                    runningBackgroundPolicy: metadata.backgroundWork,
                    localDataPolicy: metadata.localData,
                    requiredModules: metadata.dependencies.compactMap(UtilityModuleID.init(rawValue:)),
                    conflicts: metadata.conflicts,
                    settingsSchemaVersion: metadata.settingsSchemaVersion
                )
            )
        case .storage:
            let metadata = SafeEjectModule.descriptor
            return .init(
                id: .storage,
                title: metadata.name,
                summary: metadata.purpose,
                symbolName: metadata.symbol,
                disclosure: .init(
                    permissionReasons: metadata.permissions.map { .init(name: "macOS access", reason: $0) },
                    runningBackgroundPolicy: metadata.backgroundWork,
                    localDataPolicy: metadata.localDataPolicy,
                    settingsSchemaVersion: metadata.settingsSchemaVersion
                )
            )
        default:
            return descriptor
        }
    }
}
