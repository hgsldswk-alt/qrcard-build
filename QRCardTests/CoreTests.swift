import CoreImage
import PDFKit
import UIKit
import Vision
import XCTest

final class CardCodingTests: XCTestCase {
    func testURLKeepsQueryAndFragment() throws {
        let url = "https://example.com/guide?q=%E4%B8%AD&lang=zh#part-2"
        XCTAssertEqual(try CardDraft(link: " \(url)\n").encode(.link), url)
        for input in ["", "example.com", "https:///guide", "ftp://example.com", "https://ex ample.com"] {
            XCTAssertThrowsError(try CardDraft(link: input).encode(.link))
        }
    }

    func testTextIsPreservedAndLimitIsUTF8() throws {
        let text = " 简体\n繁體\nEnglish 👋 \n"
        XCTAssertEqual(try CardDraft(text: text).encode(.text), text)
        let exact = String(repeating: "🙂", count: 128)
        XCTAssertEqual(try CardDraft(text: exact).encode(.text).utf8.count, 512)
        XCTAssertThrowsError(try CardDraft(text: exact + "!").encode(.text)) { XCTAssertEqual($0 as? CardError, .tooLarge) }
        XCTAssertThrowsError(try CardDraft(text: "\n  ").encode(.text))
    }

    func testWiFiRoundTripEscapesSpecialCharacters() throws {
        let draft = CardDraft(ssid: "訪客;A:B", password: "pass\"w\\ord,!")
        let payload = try draft.encode(.wifi)
        XCTAssertEqual(payload, "WIFI:T:WPA;S:訪客\\;A\\:B;P:pass\\\"w\\\\ord\\,!;;")
        XCTAssertEqual(try card(.wifi, payload).draftForCopy().encode(.wifi), payload)
        let open = try CardDraft(ssid: "Workshop", password: "do not include", openNetwork: true).encode(.wifi)
        XCTAssertEqual(open, "WIFI:T:nopass;S:Workshop;;")
        XCTAssertTrue(card(.wifi, open).draftForCopy().openNetwork)
        XCTAssertThrowsError(try CardDraft(ssid: "Workshop").encode(.wifi))
        XCTAssertThrowsError(try CardDraft(ssid: "", openNetwork: true).encode(.wifi))
    }

    func testVCardEscapesNewlinesAndFoldsUTF8() throws {
        let name = "簡,繁;\r\nA\\B" + String(repeating: "名", count: 30)
        let draft = CardDraft(name: name, phone: "+1 555 0100", email: "demo@example.com")
        let payload = try draft.encode(.contact)
        XCTAssertTrue(payload.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        XCTAssertTrue(payload.contains("N:簡\\,繁\\;\\nA\\\\B"))
        XCTAssertTrue(payload.contains("\r\n "))
        XCTAssertTrue(payload.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 })
        let restored = card(.contact, payload).draftForCopy()
        XCTAssertEqual(restored.name, name.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(try restored.encode(.contact), payload)
        XCTAssertThrowsError(try CardDraft(name: "No details").encode(.contact))
        XCTAssertThrowsError(try CardDraft(email: "demo@example.com").encode(.contact))
    }

    func testSensitivePayloadIsExcludedFromSearchAndPromotion() {
        let privateCard = card(.wifi, "WIFI:T:WPA;S:Hidden SSID;P:demo-secret;;")
        XCTAssertEqual(privateCard.displayTitle, CardKind.wifi.label)
        XCTAssertFalse(privateCard.matches("Hidden SSID"))
        XCTAssertFalse(privateCard.matches("demo-secret"))
        XCTAssertNil(Promotion.card.content(from: privateCard, optedIn: true))
        let contact = card(.contact, "TEL:1234")
        XCTAssertFalse(contact.matches("1234"))
        XCTAssertNil(Promotion.card.content(from: contact, optedIn: true))
        let publicCard = card(.link, "https://example.com/guide")
        XCTAssertTrue(publicCard.matches("guide"))
        XCTAssertNil(Promotion.card.content(from: publicCard, optedIn: false))
        XCTAssertEqual(Promotion.card.content(from: publicCard, optedIn: true), publicCard.payload)
        XCTAssertNil(Promotion.milestone(10).content(from: publicCard, optedIn: true))
    }

    func testLayoutFileReadAndSizeLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".qrcard")
        defer { try? FileManager.default.removeItem(at: url) }
        let exchange = LayoutExchange(kind: .contact, layout: .standard)
        try exchange.fileData().write(to: url)
        XCTAssertEqual(try LayoutExchange.readFile(url), exchange)
        try Data(repeating: 32, count: 257).write(to: url)
        XCTAssertThrowsError(try LayoutExchange.readFile(url))
    }

    func testLayoutRoundTripAndDisallowedData() throws {
        let layout = LayoutExchange(kind: .wifi, layout: .standard)
        let code = try layout.code()
        XCTAssertEqual(try LayoutExchange(code: " \(code)\n"), layout)
        XCTAssertEqual(try LayoutExchange(fileData: layout.fileData()), layout)
        for input in [
            #"{"version":2,"kind":"wifi","layout":"standard"}"#,
            #"{"version":true,"kind":"wifi","layout":"standard"}"#,
            #"{"version":1,"kind":"unknown","layout":"standard"}"#,
            #"{"version":1,"kind":"wifi","layout":"unknown"}"#,
            #"{"version":1,"kind":"wifi","layout":"standard","password":"secret"}"#
        ] {
            let data = Data(input.utf8)
            XCTAssertThrowsError(try LayoutExchange(fileData: data))
            XCTAssertThrowsError(try LayoutExchange(code: "QRC1:" + data.base64EncodedString()))
        }
        XCTAssertThrowsError(try LayoutExchange(code: "QRC2:xxx"))
        XCTAssertThrowsError(try LayoutExchange(code: "QRC1:" + String(repeating: "A", count: 500)))
        XCTAssertThrowsError(try LayoutExchange(fileData: Data(repeating: 32, count: 257)))
    }
}

final class ArtworkTests: XCTestCase {
    private let context = CIContext(options: [.useSoftwareRenderer: true])

    func testQRPNGDecodesFourKindsAndDensePayload() throws {
        let drafts: [(CardKind, CardDraft)] = [
            (.link, CardDraft(link: "https://example.com/guide?q=1#top")),
            (.text, CardDraft(text: "简体 繁體 English 🙂\nsecond line")),
            (.wifi, CardDraft(ssid: "Guest;A", password: "sec,ret123")),
            (.contact, CardDraft(name: "Demo", phone: "+1 555 0100"))
        ]
        let payloads = try drafts.map { try $0.1.encode($0.0) } + [String(repeating: "a", count: 512)]
        for payload in payloads {
            let matrix = try QRMatrix(payload, context: context)
            let data = matrix.png()
            XCTAssertEqual(try barcode(in: data), payload)
            try verifyQuietZone(data, matrix: matrix)
        }
    }

    func testPrintPDFPaperAndReadableCode() throws {
        let payload = String(repeating: "abcd", count: 128)
        let matrix = try QRMatrix(payload, context: context)
        for region in ["US", "JP"] {
            let paper = PrintPaper(region: Locale.Region(region))
            let print = PrintArtwork(paper: paper, matrix: matrix, title: "Demo")
            let document = try XCTUnwrap(PDFDocument(data: print.pdf()))
            XCTAssertEqual(document.pageCount, 1)
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).width, paper.bounds.width, accuracy: 0.02)
            XCTAssertEqual(page.bounds(for: .mediaBox).height, paper.bounds.height, accuracy: 0.02)
            let thumb = page.thumbnail(of: paper.bounds.size, for: .mediaBox)
            XCTAssertEqual(try barcode(in: XCTUnwrap(thumb.pngData())), payload)
        }
    }

    func testPromotionSizeAndNoSensitiveBarcode() throws {
        let url = try XCTUnwrap(URL(string: "https://apps.apple.com/app/id123456789"))
        let wifi = card(.wifi, "WIFI:T:WPA;S:Hidden;P:Secret;;")
        XCTAssertThrowsError(try Promotion.card.artwork(card: wifi, optedIn: true, downloadURL: nil, context: context))
        let data = try Promotion.card.artwork(card: wifi, optedIn: true, downloadURL: url, context: context)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1440)
        XCTAssertEqual(try barcodes(in: data), [url.absoluteString])
    }

    private func barcodes(in data: Data) throws -> [String] {
        let image = try XCTUnwrap(CIImage(data: data))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    private func barcode(in data: Data) throws -> String? {
        try barcodes(in: data).first
    }

    private func verifyQuietZone(_ data: Data, matrix: QRMatrix) throws {
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        let side = image.width
        XCTAssertEqual(side, image.height)
        XCTAssertEqual(side % matrix.paddedSide, 0)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                            bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = try XCTUnwrap(bitmap.data).bindMemory(to: UInt8.self, capacity: side * side)
        let margin = QRMatrix.quietZone * side / matrix.paddedSide
        for y in 0..<side {
            for x in 0..<side where y < margin || y >= side - margin || x < margin || x >= side - margin {
                if pixels[y * side + x] != 255 { return XCTFail("Quiet zone is not white at \(x),\(y)") }
            }
        }
        XCTAssertEqual(pixels[margin * side + margin], 0)
    }
}

final class LibraryTests: XCTestCase {
    func testSaveRenameDeleteAndReopen() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = CardLibrary(root: folder)
        let empty = try await library.open()
        XCTAssertTrue(empty.cards.isEmpty)
        let (saved, preview) = try await library.create(draft: CardDraft(text: "First\nline"), kind: .text, layout: .standard)
        XCTAssertEqual(saved.cards.first?.id, preview.card.id)
        let renamed = try await library.rename(id: preview.card.id, title: "Handout")
        XCTAssertEqual(renamed.cards.first?.displayTitle, "Handout")

        let reopened = CardLibrary(root: folder)
        let loaded = try await reopened.open()
        XCTAssertEqual(loaded.cards.first?.payload, "First\nline")
        let png = try await reopened.exportPNG(preview.card)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
        await reopened.discardExport(png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
        let deleted = try await reopened.delete(id: preview.card.id)
        XCTAssertEqual(deleted.cards.count, 0)
        XCTAssertEqual(deleted.usage.distinct.count, 1)
    }

    func testFailedCommitDoesNotChangeInMemoryLibrary() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = CardLibrary(root: folder)
        _ = try await library.open()
        let database = folder.appendingPathComponent(LibraryDatabase.filename)
        try FileManager.default.removeItem(at: database)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
        do {
            _ = try await library.create(draft: CardDraft(text: "Do not save"), kind: .text, layout: .standard)
            XCTFail("Saving over a directory should fail")
        } catch {}
        let snapshot = try await library.open()
        XCTAssertTrue(snapshot.cards.isEmpty)
        XCTAssertTrue(snapshot.usage.distinct.isEmpty)
    }

    func testRatingAndMilestoneCountDistinctCardsAcrossDays() {
        var usage = Usage()
        let calendar = Calendar(identifier: .gregorian)
        let day1 = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)).addingTimeInterval(3600)
        let day2 = calendar.date(byAdding: .day, value: 1, to: day1)!
        XCTAssertFalse(usage.record(card(.text, "1", at: day1), calendar: calendar))
        XCTAssertFalse(usage.record(card(.text, "2", at: day1), calendar: calendar))
        XCTAssertFalse(usage.record(card(.text, "1", at: day2), calendar: calendar))
        XCTAssertFalse(usage.reviewEligible)
        XCTAssertFalse(usage.record(card(.text, "3", at: day2), calendar: calendar))
        XCTAssertTrue(usage.reviewEligible)
        usage.markReviewAttempted()
        XCTAssertFalse(usage.reviewEligible)
        for index in 4...11 {
            XCTAssertEqual(usage.record(card(.text, String(index), at: day2), calendar: calendar), index == 10)
        }
    }

    private func temporaryFolder() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
}

final class EntitlementTests: XCTestCase {
    private let day: TimeInterval = 86_400

    func testFreeVersionTimeDoesNotConsumePaidTrialAndLateReceiptDoesNotExtendIt() {
        let first = Date(timeIntervalSince1970: 1_000)
        let paid = first.addingTimeInterval(45 * day)
        var value = Entitlement(firstOpen: first)
        value.enterPaidMode(at: paid)
        XCTAssertEqual(value.trialStart, paid)
        XCTAssertTrue(value.canClaimTrial(at: paid.addingTimeInterval(20 * day)))
        value.applyTrial(paid.addingTimeInterval(20 * day))
        XCTAssertEqual(value.trialStart, paid)
        XCTAssertFalse(value.canClaimTrial(at: paid))
        XCTAssertTrue(value.hasPro(at: value.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(value.hasPro(at: value.trialEnd, free: false))
    }

    func testReinstallReceiptFallbackAndClockRollback() throws {
        let restored = Date(timeIntervalSince1970: 1_000)
        let now = restored.addingTimeInterval(31 * day)
        var value = Entitlement(firstOpen: now)
        value.enterPaidMode(at: now)
        value.applyTrial(restored)
        XCTAssertEqual(value.trialStart, restored)
        XCTAssertFalse(value.hasPro(at: now, free: false))
        XCTAssertFalse(value.hasPro(at: restored.addingTimeInterval(day), free: false))

        value.purchasedPro = true
        var offline = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(value))
        XCTAssertTrue(offline.hasPro(at: now, free: false))
        offline.purchasedPro = false
        XCTAssertFalse(offline.hasPro(at: now, free: false))
        XCTAssertTrue(offline.hasPro(at: now, free: true))
    }

    func testFallbackIsFirstOpenIfPaidStartIsMissing() {
        let first = Date(timeIntervalSince1970: 1_000)
        let value = Entitlement(firstOpen: first)
        XCTAssertEqual(value.trialStart, first)
        XCTAssertFalse(value.hasPro(at: first.addingTimeInterval(30 * day), free: false))
    }
}

private func card(_ kind: CardKind, _ payload: String, at date: Date = Date()) -> Card {
    Card(kind: kind, payload: payload, createdAt: date, layout: .standard)
}
