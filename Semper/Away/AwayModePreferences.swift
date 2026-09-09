import Foundation

nonisolated enum AwayAuthenticationMethod: String, CaseIterable, Codable, Identifiable, Sendable {
    case system = "system"
    case pin = "pin"

    var id: String { rawValue }
}

nonisolated enum AwayModeTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case stillGradient = "stillGradient"
    case aurora = "aurora"
    case quietOrbits = "quietOrbits"
    case customPhoto = "customPhoto"

    var id: String { rawValue }
}

nonisolated enum AwayModeAccent: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue = "blue"
    case violet = "violet"
    case teal = "teal"
    case amber = "amber"

    var id: String { rawValue }
}

nonisolated enum AwayWidgetPlacement: String, CaseIterable, Codable, Identifiable, Sendable {
    case topLeft = "topLeft"
    case center = "center"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"

    var id: String { rawValue }
}

nonisolated enum AwayPhotoFit: String, CaseIterable, Codable, Identifiable, Sendable {
    case fill = "fill"
    case fit = "fit"

    var id: String { rawValue }
}

nonisolated enum AwayMotionLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case off = "off"
    case subtle = "subtle"
    case standard = "standard"

    var id: String { rawValue }
}

nonisolated enum AwayDimDelay: Int, CaseIterable, Codable, Identifiable, Sendable {
    case never = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }
    var timeInterval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) }
}

nonisolated struct AwayModePreferences: Codable, Equatable, Sendable {
    var authenticationMethod: AwayAuthenticationMethod
    var disclosureCompleted: Bool
    var theme: AwayModeTheme
    var accent: AwayModeAccent
    var customMessage: String {
        didSet {
            let sanitized = Self.sanitizeCustomMessage(customMessage)
            if customMessage != sanitized {
                customMessage = sanitized
            }
        }
    }
    var showsClock: Bool
    var showsElapsedTime: Bool
    var showsBattery: Bool
    var showsAwakeState: Bool
    var widgetPlacement: AwayWidgetPlacement
    var managedPhotoFilename: String?
    var photoFit: AwayPhotoFit
    var motionLevel: AwayMotionLevel
    var keepsDisplayAwake: Bool
    var dimDelay: AwayDimDelay

    init(
        authenticationMethod: AwayAuthenticationMethod = .system,
        disclosureCompleted: Bool = false,
        theme: AwayModeTheme = .aurora,
        accent: AwayModeAccent = .blue,
        customMessage: String = "",
        showsClock: Bool = true,
        showsElapsedTime: Bool = true,
        showsBattery: Bool = true,
        showsAwakeState: Bool = true,
        widgetPlacement: AwayWidgetPlacement = .bottomLeft,
        managedPhotoFilename: String? = nil,
        photoFit: AwayPhotoFit = .fill,
        motionLevel: AwayMotionLevel = .subtle,
        keepsDisplayAwake: Bool = false,
        dimDelay: AwayDimDelay = .fiveMinutes
    ) {
        self.authenticationMethod = authenticationMethod
        self.disclosureCompleted = disclosureCompleted
        self.theme = theme
        self.accent = accent
        self.customMessage = Self.sanitizeCustomMessage(customMessage)
        self.showsClock = showsClock
        self.showsElapsedTime = showsElapsedTime
        self.showsBattery = showsBattery
        self.showsAwakeState = showsAwakeState
        self.widgetPlacement = widgetPlacement
        self.managedPhotoFilename = managedPhotoFilename
        self.photoFit = photoFit
        self.motionLevel = motionLevel
        self.keepsDisplayAwake = keepsDisplayAwake
        self.dimDelay = dimDelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedManagedPhotoFilename = try container.decodeIfPresent(
            String.self,
            forKey: .managedPhotoFilename
        )
        self.init(
            authenticationMethod: try container.decodeIfPresent(
                AwayAuthenticationMethod.self,
                forKey: .authenticationMethod
            ) ?? .system,
            disclosureCompleted: try container.decodeIfPresent(
                Bool.self,
                forKey: .disclosureCompleted
            ) ?? false,
            theme: try container.decodeIfPresent(AwayModeTheme.self, forKey: .theme) ?? .aurora,
            accent: try container.decodeIfPresent(AwayModeAccent.self, forKey: .accent) ?? .blue,
            customMessage: try container.decodeIfPresent(String.self, forKey: .customMessage) ?? "",
            showsClock: try container.decodeIfPresent(Bool.self, forKey: .showsClock) ?? true,
            showsElapsedTime: try container.decodeIfPresent(
                Bool.self,
                forKey: .showsElapsedTime
            ) ?? true,
            showsBattery: try container.decodeIfPresent(Bool.self, forKey: .showsBattery) ?? true,
            showsAwakeState: try container.decodeIfPresent(
                Bool.self,
                forKey: .showsAwakeState
            ) ?? true,
            widgetPlacement: try container.decodeIfPresent(
                AwayWidgetPlacement.self,
                forKey: .widgetPlacement
            ) ?? .bottomLeft,
            managedPhotoFilename: decodedManagedPhotoFilename.flatMap {
                AwayPhotoStore.isManagedFilename($0) ? $0 : nil
            },
            photoFit: try container.decodeIfPresent(AwayPhotoFit.self, forKey: .photoFit) ?? .fill,
            motionLevel: try container.decodeIfPresent(
                AwayMotionLevel.self,
                forKey: .motionLevel
            ) ?? .subtle,
            keepsDisplayAwake: try container.decodeIfPresent(
                Bool.self,
                forKey: .keepsDisplayAwake
            ) ?? false,
            dimDelay: try container.decodeIfPresent(AwayDimDelay.self, forKey: .dimDelay) ?? .fiveMinutes
        )
    }

    static func sanitizeCustomMessage(_ message: String) -> String {
        let filtered = message.components(separatedBy: .controlCharacters).joined()
        return String(filtered.prefix(140))
    }
}
