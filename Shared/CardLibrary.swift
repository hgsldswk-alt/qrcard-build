import CoreImage
import CryptoKit
import Foundation

struct Usage: Codable, Sendable {
    private var secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    private(set) var distinct: Set<Data> = []
    private(set) var days: Set<String> = []
    private(set) var reviewAttempted = false

    var reviewEligible: Bool { !reviewAttempted && distinct.count >= 3 && days.count >= 2 }

    mutating func record(_ card: Card, calendar: Calendar = .init(identifier: .gregorian)) -> Bool {
        let input = Data("\(card.kind.rawValue):\(card.payload)".utf8)
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: secret)))
        guard distinct.insert(fingerprint).inserted else { return false }
        let date = calendar.dateComponents([.year, .month, .day], from: card.createdAt)
        days.insert("\(date.year ?? 0)-\(date.month ?? 0)-\(date.day ?? 0)")
        return distinct.count == 10
    }

    mutating func markReviewAttempted() { reviewAttempted = true }
}

struct LibrarySnapshot: Sendable {
    var cards: [Card] = []
    var usage = Usage()
}

struct CardPreview: Sendable {
    let card: Card
    let image: Data
    var milestone = false
}

actor CardLibrary {
    private var snapshot: LibrarySnapshot?
    private let injectedRoot: URL?
    private let testScope: Bool
    private lazy var renderContext = CIContext(options: [.useSoftwareRenderer: true])

    init(root: URL? = nil, testScope: Bool = false) {
        injectedRoot = root
        self.testScope = testScope
    }

    private func support() throws -> URL {
        if let injectedRoot { return injectedRoot }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent(testScope ? "QRCard-UITests" : "QRCard", isDirectory: true)
    }

    private func exports() throws -> URL {
        if let injectedRoot { return injectedRoot.appendingPathComponent("Exports", isDirectory: true) }
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
        return cache.appendingPathComponent(testScope ? "QRCard-UIExports" : "QRCard-Exports", isDirectory: true)
    }

    func open(reset: Bool = false, seed: [Card] = []) throws -> LibrarySnapshot {
        if let snapshot { return snapshot }
        var directory = try support()
        if reset, testScope, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)

        if let cache = try? exports(), FileManager.default.fileExists(atPath: cache.path) {
            try? FileManager.default.removeItem(at: cache)
        }
        let database = try LibraryDatabase(url: directory.appendingPathComponent(LibraryDatabase.filename))
        defer { database.close() }
        if let loaded = try database.read() {
            snapshot = loaded
            return loaded
        }
        var initial = LibrarySnapshot()
        initial.cards = seed.sorted { $0.createdAt > $1.createdAt }
        for card in initial.cards { _ = initial.usage.record(card) }
        try database.write(initial)
        snapshot = initial
        return initial
    }

    private func commit(_ updated: LibrarySnapshot) throws -> LibrarySnapshot {
        let database = try LibraryDatabase(url: support().appendingPathComponent(LibraryDatabase.filename))
        defer { database.close() }
        try database.write(updated)
        snapshot = updated
        return updated
    }

    func create(draft: CardDraft, kind: CardKind, layout: CardLayout) throws -> (LibrarySnapshot, CardPreview) {
        let payload = try draft.encode(kind)
        let card = Card(kind: kind, payload: payload, createdAt: Date(), layout: layout)
        var preview = try preview(for: card)
        var updated = try open()
        updated.cards.insert(card, at: 0)
        preview.milestone = updated.usage.record(card)
        return (try commit(updated), preview)
    }

    func preview(for card: Card) throws -> CardPreview {
        CardPreview(card: card, image: try matrix(for: card).png(target: 648))
    }

    func rename(id: UUID, title: String) throws -> LibrarySnapshot {
        var updated = try open()
        guard let index = updated.cards.firstIndex(where: { $0.id == id }) else { return updated }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.cards[index].title = name.isEmpty ? nil : String(name.prefix(80))
        return try commit(updated)
    }

    func delete(id: UUID) throws -> LibrarySnapshot {
        var updated = try open()
        updated.cards.removeAll { $0.id == id }
        return try commit(updated)
    }

    func markReviewAttempted() throws -> LibrarySnapshot? {
        var updated = try open()
        guard updated.usage.reviewEligible else { return nil }
        updated.usage.markReviewAttempted()
        return try commit(updated)
    }

    private func matrix(for card: Card) throws -> QRMatrix { try QRMatrix(card.payload, context: renderContext) }

    private func export(_ data: Data, kind: String) throws -> URL {
        let directory = try exports().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(kind)
        do {
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            return file
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func discardExport(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func exportPNG(_ card: Card) throws -> URL {
        try export(matrix(for: card).png(), kind: "QRCard.png")
    }

    func printPreview(_ card: Card, paper: PrintPaper) throws -> Data {
        try printArtwork(card, paper: paper).preview()
    }

    func exportPDF(_ card: Card, paper: PrintPaper) throws -> URL {
        try export(printArtwork(card, paper: paper).pdf(), kind: "QRCard.pdf")
    }

    private func printArtwork(_ card: Card, paper: PrintPaper) throws -> PrintArtwork {
        try PrintArtwork(paper: paper, matrix: matrix(for: card), title: card.displayTitle)
    }

    func exportLayout(_ card: Card) throws -> URL {
        try export(LayoutExchange(kind: card.kind, layout: card.layout).fileData(), kind: "Layout.qrcard")
    }

    func readLayout(_ url: URL) throws -> LayoutExchange { try LayoutExchange.readFile(url) }

    func downloadPreview(_ url: URL) throws -> Data { try QRMatrix(url.absoluteString, context: renderContext).png(target: 350) }

    func exportPromotion(_ card: Card, style: Promotion, optedIn: Bool, downloadURL: URL?) throws -> URL {
        try export(style.artwork(card: card, optedIn: optedIn, downloadURL: downloadURL, context: renderContext),
                   kind: "QRCard-Share.png")
    }
}
