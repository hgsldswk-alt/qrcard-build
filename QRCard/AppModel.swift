import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Modal {
        case more, history, privacy, importLayout, exports, promotion(Promotion), printPreview, paywall, rename
    }

    @Published var kind: CardKind = .link
    @Published var draft = CardDraft()
    @Published var modal: Modal?
    @Published private(set) var detail: CardPreview?
    @Published private(set) var cards: [Card] = []
    @Published private(set) var formError: String?
    @Published private(set) var notice: String?
    @Published var alert: String?
    @Published private(set) var pendingLayout: LayoutExchange?
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var sharing = false

    let library = CardLibrary(testScope: Launch.testing)
    private var layout: CardLayout = .standard
    private var usage = Usage()
    private(set) var suppressReview = false

    func start() async {
        guard !ready, !busy else { return }
        await perform {
            let initial = try await library.open(reset: Launch.fixture("-reset"), seed: Self.sampleCards)
            update(initial)
            if Launch.testing, let text = Launch.environment["QRC_TEST_TEXT"] {
                draft.text = text
                kind = .text
            }
            if Launch.testing, let link = Launch.environment["QRC_TEST_LINK"] { draft.link = link }
            if Launch.fixture("-wifi") {
                kind = .wifi
                draft.ssid = "Studio Guest"
                draft.password = "Demo-Only-2026"
            }
            if Launch.fixture("-paywall") { modal = .paywall }
            ready = true
        }
    }

    private static var sampleCards: [Card] {
        if Launch.fixture("-milestone") {
            return (1...9).map {
                Card(kind: .text, payload: "Sample \($0)", createdAt: Date(timeIntervalSince1970: TimeInterval($0)),
                     layout: .standard)
            }
        }
        guard Launch.fixture("-seed") else { return [] }
        let menu = Card(kind: .link, payload: "https://example.com/menu", title: L.t("demo.menu"),
                        createdAt: Date(timeIntervalSince1970: 1_700_000_010), layout: .standard)
        let guest = Card(kind: .wifi, payload: "WIFI:T:WPA;S:Studio Guest;P:Demo-Only-2026;;", title: L.t("demo.guest"),
                         createdAt: Date(timeIntervalSince1970: 1_700_000_000), layout: .standard)
        return [menu, guest]
    }

    private func update(_ snapshot: LibrarySnapshot) {
        cards = snapshot.cards
        usage = snapshot.usage
    }

    private func perform(onError: ((String) -> Void)? = nil, _ operation: () async throws -> Void) async {
        guard !busy, !sharing else { return }
        busy = true
        defer { busy = false }
        do {
            try await operation()
        } catch {
            let message = (error as? CardError)?.message ?? L.t("error.storage")
            suppressReview = true
            if let onError { onError(message) } else { alert = message }
        }
    }

    func select(_ kind: CardKind) {
        self.kind = kind
        formError = nil
        notice = nil
    }

    func clearError() { formError = nil }

    func create() async {
        guard ready else { return }
        formError = nil
        notice = nil
        suppressReview = false
        await perform(onError: { self.formError = $0 }) {
            let (updated, preview) = try await library.create(draft: draft, kind: kind, layout: layout)
            update(updated)
            detail = preview
        }
    }

    func show(_ card: Card) async {
        await perform {
            let preview = try await library.preview(for: card)
            modal = nil
            detail = preview
        }
    }

    func closeDetail() { detail = nil }

    func useCopy(_ card: Card) {
        select(card.kind)
        layout = card.layout
        draft.replaceFields(for: card.kind, with: card.draftForCopy())
        modal = nil
        detail = nil
    }

    func rename(_ card: Card, to title: String) async {
        await perform {
            let updated = try await library.rename(id: card.id, title: title)
            update(updated)
            if let card = updated.cards.first(where: { $0.id == card.id }), let current = detail {
                detail = CardPreview(card: card, image: current.image, milestone: current.milestone)
            }
            modal = nil
        }
    }

    func delete(_ card: Card) async {
        await perform {
            let updated = try await library.delete(id: card.id)
            update(updated)
            detail = nil
        }
    }

    func hideMilestone() {
        detail?.milestone = false
    }

    func showImporter() {
        suppressReview = true
        pendingLayout = nil
        modal = .importLayout
    }

    func receiveFile(_ url: URL) async {
        suppressReview = true
        await perform(onError: { _ in self.alert = L.t("error.import") }) {
            let payload = try await library.readLayout(url)
            pendingLayout = payload
            modal = .importLayout
        }
    }

    func applyCode(_ value: String) {
        do {
            let exchange: LayoutExchange
            if let pendingLayout { exchange = pendingLayout } else { exchange = try LayoutExchange(code: value) }
            select(exchange.kind)
            layout = exchange.layout
            pendingLayout = nil
            modal = nil
            detail = nil
            notice = L.t("import.done")
        } catch {
            alert = L.t("error.import")
        }
    }

    func copyLayout(_ card: Card) {
        do {
            UIPasteboard.general.string = try LayoutExchange(kind: card.kind, layout: card.layout).code()
            alert = L.t("exports.copied")
        } catch {
            alert = L.t("error.import")
        }
    }

    func sharePNG(_ card: Card) async {
        await share { try await library.exportPNG(card) }
    }

    func shareLayout(_ card: Card) async {
        await share { try await library.exportLayout(card) }
    }

    func sharePDF(_ card: Card, paper: PrintPaper) async {
        await share { try await library.exportPDF(card, paper: paper) }
    }

    func sharePromotion(_ card: Card, style: Promotion, optedIn: Bool) async {
        guard let url = Launch.downloadURL else { return }
        await share { try await library.exportPromotion(card, style: style, optedIn: optedIn, downloadURL: url) }
    }

    private func share(_ export: () async throws -> URL) async {
        suppressReview = true
        await perform {
            let file = try await export()
            guard let window = UIApplication.shared.connectedScenes.compactMap({ scene -> UIWindow? in
                guard scene.activationState == .foregroundActive, let scene = scene as? UIWindowScene else { return nil }
                return scene.windows.first(where: \.isKeyWindow)
            }).first, var presenter = window.rootViewController else {
                await library.discardExport(file)
                throw CardError.render
            }
            while let presented = presenter.presentedViewController { presenter = presented }
            guard presenter.viewIfLoaded?.window != nil, !presenter.isBeingDismissed else {
                await library.discardExport(file)
                throw CardError.render
            }

            let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            activity.view.accessibilityIdentifier = "native-share-sheet"
            if let anchor = activity.popoverPresentationController {
                anchor.sourceView = presenter.view
                anchor.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
            }
            activity.completionWithItemsHandler = { [weak self, library = self.library] _, _, _, error in
                let failed = error != nil
                Task { @MainActor in
                    await library.discardExport(file)
                    self?.sharing = false
                    if failed { self?.alert = L.t("error.share") }
                }
            }
            sharing = true
            presenter.present(activity, animated: true)
        }
    }

    var reviewCandidate: Bool {
        !Launch.testing && ready && usage.reviewEligible && !suppressReview && detail == nil &&
            modal == nil && !busy && !sharing && formError == nil && alert == nil && notice == nil
    }

    func markReviewAttempted() async -> Bool {
        guard reviewCandidate else { return false }
        do {
            guard let updated = try await library.markReviewAttempted() else { return false }
            update(updated)
            return !suppressReview && detail == nil && modal == nil && !busy && !sharing && alert == nil
        } catch {
            suppressReview = true
            return false
        }
    }
}
