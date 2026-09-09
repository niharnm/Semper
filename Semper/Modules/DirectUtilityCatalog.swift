extension UtilityModuleDescriptor {
    static let integratedCatalog: [Self] = catalog.map { descriptor in
        switch descriptor.id {
        case .away:
            return .init(
                id: .away, title: descriptor.title, summary: descriptor.summary,
                symbolName: descriptor.symbolName,
                disclosure: .init(
                    permissionReasons: [
                        .init(name: "Accessibility", reason: "Filters ordinary input while the curtain is active."),
                        .init(
                            name: "Input Monitoring", reason: "May also be required if macOS denies the input filter."),
                        .init(
                            name: "Mac authentication",
                            reason: "Authorizes exit when selected, PIN changes, and Reset All Settings."),
                    ],
                    runningBackgroundPolicy:
                        "An active session covers connected displays, filters input, and holds its own Awake request. Session timers and display changes are observed while needed.",
                    localDataPolicy:
                        "Appearance settings and managed photos stay on this Mac. A salted PIN verifier is kept in the device-only Keychain. Removing Away keeps this data; Reset All Settings deletes it after authentication.",
                    conflicts: ["Other utility changes wait while Away is guarded or finishing cleanup."],
                    hardwareRequirements: [
                        "Away is a privacy curtain, not the macOS Lock Screen. Its awake request does not prevent lid-close sleep or manual Sleep."
                    ]
                ))
        case .displays:
            return .init(
                id: .displays, title: descriptor.title, summary: descriptor.summary,
                symbolName: descriptor.symbolName,
                disclosure: .init(
                    permissionReasons: [],
                    runningBackgroundPolicy: "Reads connected display capabilities and controls when requested. Supported writes are serialized; verification results stay visible. Input switching requires confirmation and is sent once.",
                    localDataPolicy: "No display preset is saved by this module. Scene settings are stored by Scenes.",
                    hardwareRequirements: ["Brightness, contrast, volume, and input availability depend on the display's DDC support. Built-in and unsupported displays remain visible with an unavailable reason."]
                ))
        case .scenes:
            return .init(
                id: .scenes, title: descriptor.title, summary: descriptor.summary,
                symbolName: descriptor.symbolName,
                disclosure: .init(
                    permissionReasons: [],
                    runningBackgroundPolicy: "Registers configured scene shortcuts while running. Applying or restoring starts only the modules needed for the selected controls.",
                    localDataPolicy: "Saved scenes and a recovery journal are stored locally. Removing Scenes keeps its library and requires pending recovery to be settled.",
                    selectedModules: [.awake, .sound, .displays],
                    conflicts: ["End Away before applying or restoring a scene. A Presentation session owns its scene recovery until it ends."],
                    settingsSchemaVersion: 1
                ))
        case .presentation:
            return .init(
                id: .presentation, title: descriptor.title, summary: descriptor.summary,
                symbolName: descriptor.symbolName,
                disclosure: .init(
                    permissionReasons: [],
                    runningBackgroundPolicy: "Active sessions hold a finite Awake request and a duration timer. Only explicitly selected controls are applied after preview.",
                    localDataPolicy: "Display and Sound recovery uses the scene journal. Window recovery stays in this running session and must finish before its Workspace service is removed.",
                    requiredModules: [.awake], selectedModules: [.displays, .workspace, .sound],
                    conflicts: ["End Away before preparing Presentation. Restore or keep an existing scene before starting another session."]
                ))
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
