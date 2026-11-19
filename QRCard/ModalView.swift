import SwiftUI
import UIKit

struct ModalView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        switch model.modal {
        case .more:
            SheetPage(title: L.t("home.more"), close: close) {
                Button(L.t("import.title")) { model.showImporter() }
                    .accessibilityIdentifier("more-import")
                Button(L.t("privacy.title")) { model.modal = .privacy }
                    .accessibilityIdentifier("more-privacy")
                if !Launch.isFree {
                    Button(L.t("purchase.title")) { model.modal = .paywall }
                        .accessibilityIdentifier("more-pro")
                    Button(L.t("purchase.restore")) {
                        model.modal = .paywall
                        Task { await purchases.restore() }
                    }
                    .accessibilityIdentifier("more-restore")
                    .disabled(purchases.busy)
                }
            }
            .buttonStyle(CardActionStyle())
        case .history:
            HistoryView(model: model)
        case .privacy:
            SheetPage(title: L.t("privacy.title"), close: close) {
                Text(L.t("privacy.local"))
                Text(L.t("privacy.sensitive"))
                Text(L.t("privacy.apple"))
                Text(L.t("privacy.deletion"))
            }
        case .importLayout:
            ImportView(model: model)
        case .exports:
            if let card = model.detail?.card { exportOptions(for: card) }
        case .promotion(let style):
            if let preview = model.detail { PromotionView(model: model, preview: preview, style: style) }
        case .printPreview:
            if let card = model.detail?.card { PrintView(model: model, purchases: purchases, card: card) }
        case .paywall:
            PaywallView(purchases: purchases, close: close)
        case .rename:
            if let card = model.detail?.card { RenameView(model: model, card: card) }
        case nil:
            EmptyView()
        }
    }

    private func close() { model.modal = nil }

    private func exportOptions(for card: Card) -> some View {
        SheetPage(title: L.t("result.exports"), close: close) {
            Button(L.t("print.title")) {
                if purchases.hasPro {
                    let paper = PrintPaper(region: Locale.current.region)
                    Task { await model.sharePDF(card, paper: paper) }
                } else {
                    model.modal = .paywall
                }
            }
            .accessibilityIdentifier("exports-print")
            .disabled(model.busy || model.sharing)
            if purchases.hasPro {
                Button(L.t("print.previewAction")) { model.modal = .printPreview }
                    .accessibilityIdentifier("exports-print-preview")
            }
            if !Launch.isFree, !Launch.fixture("-store-shots"), purchases.entitlement?.purchasedPro != true {
                Text(L.t("purchase.terms")).font(.footnote).foregroundStyle(Palette.muted)
            }
            Button(L.t("exports.copyCode")) { model.copyLayout(card) }
                .accessibilityIdentifier("exports-copy-code")
            Button(L.t("exports.shareFile")) { Task { await model.shareLayout(card) } }
                .accessibilityIdentifier("exports-share-layout")
            Text(L.t("exports.layoutHint")).font(.footnote).foregroundStyle(Palette.muted)
        }
        .buttonStyle(CardActionStyle())
    }
}

private struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""

    var body: some View {
        SheetPage(title: L.t("history.title"), close: { model.modal = nil }) {
            TextField(L.t("history.search"), text: $query)
                .fieldSurface()
                .accessibilityIdentifier("history-search")
            let results = model.cards.filter { $0.matches(query.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if results.isEmpty {
                Text(L.t("history.noResults")).foregroundStyle(Palette.muted)
            } else {
                CardRows(cards: results, model: model, idPrefix: "history")
            }
        }
    }
}

private struct ImportView: View {
    @ObservedObject var model: AppModel
    @State private var code = ""
    @State private var choosingFile = false

    var body: some View {
        SheetPage(title: L.t("import.title"), close: { model.modal = nil }) {
            Text(L.t("import.hint")).font(.subheadline).foregroundStyle(Palette.muted)
            if let pending = model.pendingLayout {
                Text(L.f("import.type", pending.kind.label))
                    .font(.headline)
                    .accessibilityIdentifier("import-file-preview")
            } else {
                TextField(L.t("import.code"), text: $code, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(.vertical, 10)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .fieldSurface()
                    .accessibilityIdentifier("import-code")
                PasteButton(payloadType: String.self) { values in
                    if let pasted = values.first { code = pasted }
                }
                .accessibilityIdentifier("import-paste")
            }
            Button(L.t("import.title")) { model.applyCode(code) }
                .buttonStyle(CardActionStyle(primary: true))
                .accessibilityIdentifier("import-confirm")
                .disabled(model.busy)
            Button(L.t("import.choose")) { choosingFile = true }
                .buttonStyle(CardActionStyle())
                .accessibilityIdentifier("import-file")
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [LayoutExchange.fileType]) { outcome in
            switch outcome {
            case .success(let url): Task { await model.receiveFile(url) }
            case .failure: model.alert = L.t("error.import")
            }
        }
    }
}

private struct RenameView: View {
    @ObservedObject var model: AppModel
    let card: Card
    @State private var title = ""

    var body: some View {
        SheetPage(title: L.t("result.rename"), close: { model.modal = nil }) {
            TextField(L.t("rename.title"), text: $title)
                .fieldSurface()
                .accessibilityIdentifier("rename-title")
            Button(L.t("action.save")) { Task { await model.rename(card, to: title) } }
                .buttonStyle(CardActionStyle(primary: true))
                .accessibilityIdentifier("rename-save")
                .disabled(model.busy)
        }
        .onAppear { title = card.title ?? "" }
    }
}

private struct PrintView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
    let card: Card
    @State private var image: Data?
    private var paper: PrintPaper { PrintPaper(region: Locale.current.region) }

    var body: some View {
        SheetPage(title: L.t("print.title"), close: { model.modal = nil }) {
            Text(L.f("print.paper", paper.label)).font(.subheadline).foregroundStyle(Palette.muted)
            if let image, let preview = UIImage(data: image), purchases.hasPro {
                Image(uiImage: preview)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 360)
                    .surface(radius: 4)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(L.t("print.title"))
                    .accessibilityIdentifier("print-preview")
            }
            Button {
                if purchases.hasPro {
                    Task { await model.sharePDF(card, paper: paper) }
                } else {
                    model.modal = .paywall
                }
            } label: {
                Label(L.t(purchases.hasPro ? "print.share" : "purchase.title"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(CardActionStyle(primary: true))
            .accessibilityIdentifier("print-share")
            .disabled((purchases.hasPro && image == nil) || model.busy || model.sharing)
        }
        .task {
            guard purchases.hasPro else { return }
            do { image = try await model.library.printPreview(card, paper: paper) }
            catch { model.alert = L.t("error.render") }
        }
    }
}
