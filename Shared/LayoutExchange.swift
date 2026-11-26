import CoreFoundation
import Foundation
import UniformTypeIdentifiers

struct LayoutExchange: Equatable, Sendable {
    static let fileType = UTType(exportedAs: "com.hgsldswk.qrcard.layout")
    static let prefix = "QRC1:"
    static let maximumBytes = 256

    let kind: CardKind
    let layout: CardLayout

    func fileData() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "kind": kind.rawValue, "layout": layout.rawValue],
                                   options: [.sortedKeys])
    }

    func code() throws -> String { Self.prefix + (try fileData()).base64EncodedString() }

    init(kind: CardKind, layout: CardLayout) {
        self.kind = kind
        self.layout = layout
    }

    init(fileData data: Data) throws {
        guard data.count <= Self.maximumBytes,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(raw.keys) == ["version", "kind", "layout"],
              let version = raw["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == 1,
              let kind = (raw["kind"] as? String).flatMap(CardKind.init(rawValue:)),
              let layout = (raw["layout"] as? String).flatMap(CardLayout.init(rawValue:)) else {
            throw CardError.importFormat
        }
        self.init(kind: kind, layout: layout)
    }

    init(code: String) throws {
        guard code.utf8.prefix(401).count <= 400 else { throw CardError.importFormat }
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(Self.prefix),
              let data = Data(base64Encoded: String(value.dropFirst(Self.prefix.count))) else {
            throw CardError.importFormat
        }
        try self.init(fileData: data)
    }

    static func readFile(_ url: URL) throws -> Self {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard url.pathExtension.lowercased() == "qrcard" else { throw CardError.importFormat }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var data = Data()
        while let chunk = try file.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maximumBytes { throw CardError.importFormat }
        }
        return try Self(fileData: data)
    }
}
