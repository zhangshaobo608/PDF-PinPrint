import Foundation

/// Document-independent layout options. A preset deliberately excludes page ranges.
struct PrintLayout: Codable, Equatable {
    var pagesPerSheet: Int
    var paperIndex: Int
    var landscape: Bool
    var arrangement: Int
    var marginIndex: Int
    var showsBorders: Bool

    var isValid: Bool {
        (1...16).contains(pagesPerSheet)
            && (0...2).contains(paperIndex)
            && (0...2).contains(arrangement)
            && (0...2).contains(marginIndex)
    }
}

struct SavedPrintPreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var layout: PrintLayout
}

enum PrintPresetError: LocalizedError {
    case nameRequired
    case nameTooLong
    case nameExists
    case invalidLayout
    case notFound
    case saveFailed

    var errorDescription: String? {
        let key: String
        switch self {
        case .nameRequired: key = "preset.error.name_required"
        case .nameTooLong: key = "preset.error.name_too_long"
        case .nameExists: key = "preset.error.name_exists"
        case .invalidLayout: key = "preset.error.invalid_layout"
        case .notFound: key = "preset.error.not_found"
        case .saveFailed: key = "preset.error.save_failed"
        }
        return L10n.string(key)
    }
}

final class PrintPresetStore {
    private static let storageKey = "savedPrintPresets.v1"
    private let defaults: UserDefaults
    private(set) var presets: [SavedPrintPreset]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presets = Self.load(from: defaults)
    }

    @discardableResult
    func add(name: String, layout: PrintLayout) throws -> SavedPrintPreset {
        let name = try validatedName(name)
        guard layout.isValid else { throw PrintPresetError.invalidLayout }
        let preset = SavedPrintPreset(id: UUID(), name: name, layout: layout)
        try persist(presets + [preset])
        return preset
    }

    func rename(id: UUID, name: String) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw PrintPresetError.notFound
        }
        let name = try validatedName(name, excluding: id)
        var updated = presets
        updated[index].name = name
        try persist(updated)
    }

    func remove(id: UUID) throws {
        guard let index = presets.firstIndex(where: { $0.id == id }) else {
            throw PrintPresetError.notFound
        }
        var updated = presets
        updated.remove(at: index)
        try persist(updated)
    }

    func validatedName(_ rawName: String, excluding id: UUID? = nil) throws -> String {
        let name = Self.trimmedName(rawName)
        guard !name.isEmpty else { throw PrintPresetError.nameRequired }
        guard name.count <= 60 else { throw PrintPresetError.nameTooLong }
        let key = Self.nameKey(name)
        guard !presets.contains(where: { $0.id != id && Self.nameKey($0.name) == key }) else {
            throw PrintPresetError.nameExists
        }
        return name
    }

    private func persist(_ updated: [SavedPrintPreset]) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(updated)
        } catch {
            throw PrintPresetError.saveFailed
        }
        // UserDefaults does not report disk-write errors. Encode the entire candidate
        // first, then publish it only after handing the data to the preferences store.
        defaults.set(data, forKey: Self.storageKey)
        presets = updated
    }

    private static func load(from defaults: UserDefaults) -> [SavedPrintPreset] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([DecodedEntry].self, from: data) else {
            return []
        }
        var result: [SavedPrintPreset] = []
        var seenIDs = Set<UUID>()
        var seenNames = Set<String>()
        for entry in entries {
            guard var preset = entry.preset, preset.layout.isValid else { continue }
            preset.name = trimmedName(preset.name)
            guard !preset.name.isEmpty, preset.name.count <= 60 else { continue }
            let key = nameKey(preset.name)
            guard !seenIDs.contains(preset.id), !seenNames.contains(key) else { continue }
            seenIDs.insert(preset.id)
            seenNames.insert(key)
            result.append(preset)
        }
        return result
    }

    private static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// A damaged entry must not prevent the other presets from being loaded.
    private struct DecodedEntry: Decodable {
        let preset: SavedPrintPreset?

        init(from decoder: Decoder) throws {
            preset = try? SavedPrintPreset(from: decoder)
        }
    }
}
