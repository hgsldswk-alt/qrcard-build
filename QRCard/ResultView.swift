import SwiftUI
import UIKit

struct ResultView: View {
    @ObservedObject var model: AppModel
    let preview: CardPreview
    @State private var confirmingDelete = false

    private var card: Card { preview.card }

    var body: some View {
        Page {
            Button {
                model.closeDetail()
            } label: {
                Label(L.t("result.back"), systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .foregroundStyle(Palette.brand)
            .accessibilityIdentifier("result-back")

            VStack(alignment: .leading, spacing: 5) {
                Label(L.t("result.saved"), systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.brand)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Palette.tint, in: Capsule())
                    .accessibilityIdentifier("result-saved")
                Text(card.displayTitle)
                    .font(.largeTitle.bold()).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("result-title")
                Text(card.kind.qrLabel)
                    .font(.subheadline).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("result-kind")
            }

            VStack(spacing: 8) {
                AccessibleQR(bytes: preview.image, size: 216, title: card.kind.qrLabel)
                    .accessibilityIdentifier("result-qr")
                if let content = card.publicContent {
                    Text(content).font(.caption).foregroundStyle(Palette.muted).lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 17).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .surface()

            VStack(spacing: 8) {
                Button {
                    Task { await model.sharePNG(card) }
                } label: {
                    Label(L.t("result.sharePNG"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(CardActionStyle(primary: true))
                .accessibilityIdentifier("result-share-png")
                HStack(spacing: 8) {
                    Button(L.t("result.shareCard")) { model.modal = .promotion(.card) }
                        .accessibilityIdentifier("result-promotion")
                    Button(L.t("result.exports")) { model.modal = .exports }
                        .accessibilityIdentifier("result-exports")
                }
                .buttonStyle(CardActionStyle())
            }
            .disabled(model.busy || model.sharing)

            if card.kind.isSensitive || card.kind == .link {
                Text(L.t(card.kind.isSensitive ? "privacy.sensitive" : "result.offline"))
                    .font(.caption).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if preview.milestone { milestone }

            HStack(spacing: 8) {
                Button(L.t("result.copy")) { model.useCopy(card) }
                    .accessibilityIdentifier("result-copy")
                Button(L.t("result.rename")) { model.modal = .rename }
                    .accessibilityIdentifier("result-rename")
                Button(L.t("result.delete"), role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("result-delete")
            }
            .buttonStyle(CardActionStyle())
            .disabled(model.busy || model.sharing)
            .padding(.top, 6)
        }
        .alert(L.t("delete.title"), isPresented: $confirmingDelete) {
            Button(L.t("result.delete"), role: .destructive) { Task { await model.delete(card) } }
                .accessibilityIdentifier("confirm-delete")
            Button(L.t("action.cancel"), role: .cancel) {}
                .accessibilityIdentifier("cancel-delete")
        } message: {
            Text(L.t("delete.note"))
        }
    }

    private var milestone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(L.t("milestone.note")).font(.subheadline.weight(.semibold))
                Spacer()
                IconAction(icon: "xmark", title: L.t("action.close"), id: "milestone-close") { model.hideMilestone() }
            }
            Button(L.t("milestone.action")) {
                model.hideMilestone()
                model.modal = .promotion(.milestone(10))
            }
            .buttonStyle(CardActionStyle())
            .accessibilityIdentifier("milestone-open")
        }
        .padding(12)
        .surface(color: Palette.tint)
    }
}

struct PromotionView: View {
    @ObservedObject var model: AppModel
    let preview: CardPreview
    let style: Promotion
    @State private var optedIn = false
    @State private var download: Data?

    private var showsContent: Bool { style.content(from: preview.card, optedIn: optedIn) != nil }
    private var permitsContent: Bool { style.content(from: preview.card, optedIn: true) != nil }

    var body: some View {
        SheetPage(title: L.t(style == .card ? "result.shareCard" : "milestone.action"),
                  close: { model.modal = nil }) {
            if style == .card {
                Text(L.t(permitsContent ? "promo.publicHint" : "promo.privateHint"))
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
            artwork
            if permitsContent {
                Toggle(L.t("promo.include"), isOn: $optedIn)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("promotion-include")
            }
            if Launch.downloadURL == nil {
                Text(L.t("promo.unavailable"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("promotion-unavailable")
            }
            Text(L.t("promo.hashtags")).font(.footnote).foregroundStyle(Palette.muted)
            Button {
                Task { await model.sharePromotion(preview.card, style: style, optedIn: optedIn) }
            } label: { Label(L.t("promo.share"), systemImage: "square.and.arrow.up") }
                .buttonStyle(CardActionStyle(primary: true))
                .accessibilityIdentifier("promotion-share")
                .disabled(download == nil || model.busy || model.sharing)
            Button(L.t("promo.copyTags")) {
                UIPasteboard.general.string = L.t("promo.hashtags")
                model.alert = L.t("promo.tagsCopied")
            }
            .buttonStyle(CardActionStyle())
            .accessibilityIdentifier("promotion-copy-tags")
        }
        .task {
            guard let url = Launch.downloadURL else { return }
            do { download = try await model.library.downloadPreview(url) }
            catch { model.alert = L.t("error.render") }
        }
    }

    private var artwork: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(style.heading(includesContent: showsContent))
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if showsContent {
                Text(L.t("promo.scan")).font(.caption).foregroundStyle(Palette.muted)
                AccessibleQR(bytes: preview.image, size: 150, title: L.t("promo.contentLabel"))
                    .frame(maxWidth: .infinity).accessibilityIdentifier("promotion-content-qr")
            } else if case .milestone = style {
                Text(L.t("promo.reuse")).font(.subheadline)
            }
            Divider().padding(.top, 8)
            HStack(spacing: 12) {
                Text(L.t("promo.download")).font(.caption.weight(.semibold)).foregroundStyle(Palette.brand)
                Spacer(minLength: 0)
                if let download {
                    AccessibleQR(bytes: download, size: 82, title: L.t("promo.download"))
                } else {
                    Image(systemName: "qrcode")
                        .font(.title2)
                        .foregroundStyle(Palette.muted)
                        .frame(width: 62, height: 62)
                        .background(Palette.white, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 284)
        .surface(radius: 14, color: Palette.tint)
        .frame(maxWidth: .infinity)
    }
}
