import Foundation
import SwiftUI

/// The stored state of one strip inside a scene. Strips are keyed by their OSC `base`
/// ("/ch/01", "/bus/2", "/lr"), because `Strip.Kind` is not Codable.
struct SceneStripState: Codable, Equatable {
    var base: String
    var fader: Float
    var isOn: Bool
    /// Nil for strips without a pan control.
    var pan: Float?
    var sends: [Float]
}

/// A captured copy of the mixer state: every strip plus the 4 mute groups.
struct SceneSnapshot: Codable, Equatable {
    var strips: [SceneStripState]
    var muteGroups: [Bool]

    func state(for base: String) -> SceneStripState? {
        strips.first { $0.base == base }
    }

    /// Edits one strip in place (used to build the demo show).
    mutating func edit(_ base: String, faderDecibels: Float? = nil, isOn: Bool? = nil, sendIndex: Int? = nil, sendDecibels: Float? = nil) {
        guard let index = strips.firstIndex(where: { $0.base == base }) else { return }
        if let faderDecibels { strips[index].fader = decibelsToFader(faderDecibels) }
        if let isOn { strips[index].isOn = isOn }
        if let sendIndex, let sendDecibels, sendIndex < strips[index].sends.count {
            strips[index].sends[sendIndex] = decibelsToFader(sendDecibels)
        }
    }
}

/// One scene in the order of service.
struct ShowScene: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    /// Short description shown under the name, e.g. "Pulpito only · band muted".
    var note: String
    var snapshot: SceneSnapshot
    var savedAt = Date()
}

/// A named part of the service (WORSHIP, SERMON…) holding scenes in order.
struct ShowSection: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var scenes: [ShowScene] = []
}

/// What a recall must never touch.
struct RecallSafes: Codable, Equatable {
    /// Bus numbers 1-6: sends to these buses (and the bus master itself) stay as they are.
    var buses: Set<Int> = []
    /// Strip bases that are skipped completely.
    var strips: Set<String> = []
}

/// The show file: sections with scenes, the live scene and the recall safes.
struct Show: Codable, Equatable {
    var name: String
    var sections: [ShowSection]
    var currentSceneID: UUID?
    var safes = RecallSafes()
    var savedAt = Date()

    static let defaultSectionTitles = ["PRE-SERVICE", "WORSHIP", "SERMON", "RESPONSE", "POST"]

    static func empty(name: String) -> Show {
        Show(name: name, sections: defaultSectionTitles.map { ShowSection(title: $0) })
    }

    var scenes: [ShowScene] { sections.flatMap(\.scenes) }
}

/// Which list a change belongs to in the recall preview.
enum SceneChangeGroup: Int, CaseIterable, Identifiable {
    case faders, mutes, sends, pan

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .faders: return L("FADERS")
        case .mutes: return L("MUTES")
        case .sends: return L("SENDS")
        case .pan: return L("PAN")
        }
    }
}

/// Colour of the "to" value in the preview.
enum SceneChangeTone {
    case up, down, muted, onAir, neutral

    var color: Color {
        switch self {
        case .up, .onAir: return Theme.greenText
        case .down: return Theme.accentText
        case .muted: return Theme.muteBorder
        case .neutral: return Theme.textBright
        }
    }
}

/// The value a change writes to the mixer.
enum SceneChangeAction: Equatable {
    case fader(base: String, from: Float, to: Float)
    case mute(base: String, isOn: Bool)
    case send(base: String, index: Int, to: Float)
    case pan(base: String, to: Float)
    case muteGroup(number: Int, isOn: Bool)
}

/// One row of the recall preview: a single value that differs from the live mixer.
struct SceneChange: Identifiable {
    let id: String
    let group: SceneChangeGroup
    let name: String
    let color: Color
    let from: String
    let to: String
    let tone: SceneChangeTone
    let action: SceneChangeAction
}

/// All differences between a scene and the live mixer, with the safes applied.
struct SceneDiff {
    var changes: [SceneChange] = []
    /// Differences that were left out because of the recall safes.
    var keptSafe = 0

    func changes(in group: SceneChangeGroup) -> [SceneChange] {
        changes.filter { $0.group == group }
    }
}

/// A channel with signal that the recall is about to silence.
struct SceneWarning: Identifiable {
    let id: String
    let name: String
    let level: Float
    /// What the recall does to it, e.g. "pulls it to −∞" or "mutes it".
    let action: String
}

/// Everything needed to undo the last recall.
struct SceneUndoState {
    let snapshot: SceneSnapshot
    let previousSceneID: UUID?
    let sceneLabel: String
    let date: Date
}
