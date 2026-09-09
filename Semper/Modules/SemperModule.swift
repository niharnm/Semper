import Foundation

enum SemperModule: String, CaseIterable, Identifiable, Sendable {
    case home
    case sound
    case awake
    case displays
    case away

    static let initial: SemperModule = .home

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: "Home"
        case .sound: "Sound"
        case .awake: "Awake"
        case .displays: "Displays"
        case .away: "Away"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house.fill"
        case .sound: "speaker.wave.2.fill"
        case .awake: "sun.max.fill"
        case .displays: "display.2"
        case .away: "eye.slash.fill"
        }
    }
}
