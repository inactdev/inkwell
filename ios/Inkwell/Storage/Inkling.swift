import Foundation

/// The on-device record of a captured idea. Identity is `id`, generated once
/// and never reused - mirrors the backend's front-matter contract even
/// though this struct itself is a device-local implementation detail, not
/// the wire format (see docs/api-contract.md for the JSON shape and the
/// markdown front matter this becomes on the backend).
struct Inkling: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    /// Filename of the utterance recording within the same on-device
    /// directory as this record's JSON, if one was captured.
    var audioFileName: String?
    /// Set once the backend has confirmed receipt. Nil means "not yet synced."
    var syncedAt: Date?

    var isSynced: Bool { syncedAt != nil }

    /// A human-readable title derived from the text, for list display only -
    /// never stored separately, since the transcript is the one source of truth.
    var title: String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Untitled" }
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}
