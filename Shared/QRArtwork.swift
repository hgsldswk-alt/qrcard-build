import CoreImage
import UIKit

struct QRMatrix: Sendable {
    static let quietZone = 4

    let side: Int
    private let dark: [Bool]

    init(_ payload: String, context: CIContext) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw CardError.render }
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let image = context.createCGImage(output, from: output.extent.integral) else { throw CardError.render }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let decoded = pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
            guard let bitmap = CGContext(data: buffer.baseAddress, width: width, height: height,
                                         bitsPerComponent: 8, bytesPerRow: width,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(rect)
            bitmap.interpolationQuality = .none
            bitmap.draw(image, in: rect)
            return true
        }
        guard decoded else { throw CardError.render }

        var left = width
        var top = height
        var right = -1
        var bottom = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                left = min(x, left)
                right = max(x, right)
                top = min(y, top)
                bottom = max(y, bottom)
            }
        }
        let side = right - left + 1
        guard side >= 21, side == bottom - top + 1, (side - 21).isMultiple(of: 4) else {
            throw CardError.render
        }
        self.side = side
        dark = (top...bottom).flatMap { y in (left...right).map { x in pixels[y * width + x] < 128 } }
    }

    var paddedSide: Int { side + 2 * Self.quietZone }

    func draw(in box: CGRect, context: CGContext, integerScale: Bool) {
        let available = min(box.width, box.height) / CGFloat(paddedSide)
        let unit = integerScale ? available.rounded(.down) : available
        guard unit > 0 else { return }
        let extent = CGFloat(paddedSide) * unit
        let x = box.midX - extent / 2
        let y = box.midY - extent / 2
        let origin = CGPoint(x: integerScale ? x.rounded(.down) : x, y: integerScale ? y.rounded(.down) : y)
        context.saveGState()
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: origin, size: CGSize(width: extent, height: extent)))
        context.setFillColor(gray: 0, alpha: 1)
        context.setShouldAntialias(false)
        for row in 0..<side {
            for column in 0..<side where dark[row * side + column] {
                context.fill(CGRect(x: origin.x + CGFloat(column + Self.quietZone) * unit,
                                    y: origin.y + CGFloat(row + Self.quietZone) * unit,
                                    width: unit, height: unit))
            }
        }
        context.restoreGState()
    }

    func png(target: Int = 1024) -> Data {
        let dimension = paddedSide * max(1, target / paddedSide)
        return QRArtwork.png(width: dimension, height: dimension) { context in
            draw(in: CGRect(x: 0, y: 0, width: dimension, height: dimension), context: context, integerScale: true)
        }
    }
}

enum PrintPaper: Sendable {
    case a4, letter

    init(region: Locale.Region?) {
        self = ["US", "CA", "MX", "PH"].contains(region?.identifier ?? "") ? .letter : .a4
    }

    var bounds: CGRect {
        switch self {
        case .letter: CGRect(x: 0, y: 0, width: 612, height: 792)
        case .a4: CGRect(x: 0, y: 0, width: 210.0 * 72 / 25.4, height: 297.0 * 72 / 25.4)
        }
    }

    var label: String {
        switch self {
        case .letter: L.t("paper.letter")
        case .a4: L.t("paper.a4")
        }
    }
}

struct PrintArtwork: Sendable {
    let paper: PrintPaper
    let matrix: QRMatrix
    let title: String

    func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: paper.bounds).pdfData { context in
            context.beginPage()
            draw(in: context.cgContext, integerScale: false)
        }
    }

    func preview() -> Data {
        let bounds = paper.bounds
        return QRArtwork.png(width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded())) {
            draw(in: $0, integerScale: true)
        }
    }

    private func draw(in context: CGContext, integerScale: Bool) {
        let bounds = paper.bounds
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        let width = min(324, bounds.width - 100)
        let box = CGRect(x: bounds.midX - width / 2, y: bounds.midY - width / 2, width: width, height: width)
        let text = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        QRArtwork.drawText(String(text.prefix(90)), in: CGRect(x: 54, y: box.minY - 86, width: bounds.width - 108, height: 78),
                           font: .systemFont(ofSize: 27, weight: .semibold), color: .black, centered: true)
        matrix.draw(in: box, context: context, integerScale: integerScale)
        QRArtwork.drawText(L.t("print.scan"), in: CGRect(x: 54, y: box.maxY + 18, width: bounds.width - 108, height: 36),
                           font: .systemFont(ofSize: 16), color: .black, centered: true)
    }
}

enum QRArtwork {
    static func png(width: Int, height: Int, drawing: (CGContext) -> Void) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            drawing(context.cgContext)
        }
    }

    static func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .natural
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
    }
}

enum Promotion: Equatable, Sendable {
    case card
    case milestone(Int)

    func content(from card: Card, optedIn: Bool) -> String? {
        guard self == .card, optedIn else { return nil }
        return card.publicContent
    }

    func heading(includesContent: Bool) -> String {
        switch self {
        case .card: includesContent ? L.t("promo.activity") : L.t("app.name")
        case .milestone(let count): L.f("promo.count", count)
        }
    }

    func artwork(card: Card, optedIn: Bool, downloadURL: URL?, context: CIContext) throws -> Data {
        guard let downloadURL else { throw CardError.render }
        let content = try content(from: card, optedIn: optedIn).map { try QRMatrix($0, context: context) }
        let download = try QRMatrix(downloadURL.absoluteString, context: context)
        let heading = heading(includesContent: content != nil)
        let brand = UIColor(red: 74 / 255, green: 59 / 255, blue: 179 / 255, alpha: 1)
        let ink = UIColor(red: 28 / 255, green: 27 / 255, blue: 49 / 255, alpha: 1)
        return QRArtwork.png(width: 1080, height: 1440) { context in
            context.setFillColor(UIColor(red: 238 / 255, green: 235 / 255, blue: 1, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 1440))
            QRArtwork.drawText(heading, in: CGRect(x: 64, y: 100, width: 952, height: 210),
                               font: .systemFont(ofSize: 66, weight: .bold), color: ink)
            if let content {
                QRArtwork.drawText(L.t("promo.scan"), in: CGRect(x: 64, y: 285, width: 952, height: 65),
                                   font: .systemFont(ofSize: 36), color: ink)
                content.draw(in: CGRect(x: 250, y: 360, width: 580, height: 580), context: context, integerScale: true)
            } else if case .milestone = self {
                QRArtwork.drawText(L.t("promo.reuse"), in: CGRect(x: 64, y: 400, width: 952, height: 190),
                                   font: .systemFont(ofSize: 47), color: ink)
            }
            context.setFillColor(brand.cgColor)
            context.fill(CGRect(x: 64, y: 978, width: 952, height: 2))
            QRArtwork.drawText(L.t("promo.download"), in: CGRect(x: 64, y: 1140, width: 590, height: 155),
                               font: .systemFont(ofSize: 44, weight: .semibold), color: brand)
            download.draw(in: CGRect(x: 675, y: 1015, width: 340, height: 340), context: context, integerScale: true)
        }
    }
}
