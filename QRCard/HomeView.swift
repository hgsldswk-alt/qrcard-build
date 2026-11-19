import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @FocusState private var focus: String?
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 36

    var body: some View {
        Page {
            HStack {
                Text(L.t("app.name")).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(Palette.brand)
                Spacer()
                IconAction(icon: "ellipsis", title: L.t("home.more"), id: "home-more") {
                    focus = nil
                    model.modal = .more
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L.t("home.heading"))
                    .font(.system(size: heroSize, weight: .bold))
                    .tracking(-0.85)
                    .accessibilityAddTraits(.isHeader)
                Text(L.t("home.subtitle"))
                    .font(.subheadline)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            .padding(.bottom, 9)
            modeSelector
            form
            recent.padding(.top, 9)
            Text(L.t("home.offline"))
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
    }

    private var modeSelector: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: typeSize.isAccessibilitySize ? 2 : 4), spacing: 2) {
            ForEach(CardKind.allCases) { kind in
                Button {
                    focus = nil
                    model.select(kind)
                } label: {
                    Text(kind.label)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(kind == model.kind ? Palette.brand : Palette.muted)
                        .background(kind == model.kind ? Palette.white : .clear, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(kind == model.kind ? .isSelected : [])
                .accessibilityIdentifier("type-\(kind.rawValue)")
            }
        }
        .padding(3)
        .background(Palette.rail, in: RoundedRectangle(cornerRadius: 15))
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            fields
            if model.kind.isSensitive {
                Text(L.t("privacy.sensitive")).font(.caption).foregroundStyle(Palette.muted)
            }
            if let error = model.formError {
                Text(error).font(.footnote).foregroundStyle(Palette.error).accessibilityIdentifier("form-error")
            }
            if let notice = model.notice {
                Text(notice).font(.footnote).foregroundStyle(Palette.brand).accessibilityIdentifier("import-notice")
            }
            Button(L.t("home.generate")) {
                focus = nil
                Task { await model.create() }
            }
            .buttonStyle(CardActionStyle(primary: true))
            .accessibilityIdentifier("home-generate")
            .disabled(!model.ready || model.busy || model.sharing)
            Text(L.t("home.autosave")).font(.caption).foregroundStyle(Palette.muted)
            if !model.ready && !model.busy {
                Button(L.t("action.retry")) { Task { await model.start() } }
                    .buttonStyle(CardActionStyle())
                    .accessibilityIdentifier("library-retry")
            }
        }
        .padding(17)
        .surface()
        .onChange(of: focus) { _, value in if value != nil { model.clearError() } }
    }

    @ViewBuilder private var fields: some View {
        switch model.kind {
        case .link:
            field("field.url", hint: "https://", value: $model.draft.link, id: "field-link", keyboard: .URL)
        case .text:
            VStack(alignment: .leading, spacing: 5) {
                Text(L.t("field.text")).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                TextField(L.t("field.text"), text: $model.draft.text, axis: .vertical)
                    .lineLimit(3...6)
                    .padding(.vertical, 10)
                    .fieldSurface()
                    .focused($focus, equals: "field-text")
                    .accessibilityLabel(L.t("field.text"))
                    .accessibilityIdentifier("field-text")
            }
        case .wifi:
            field("field.ssid", value: $model.draft.ssid, id: "field-ssid")
            Toggle(L.t("field.openNetwork"), isOn: $model.draft.openNetwork)
                .font(.subheadline).accessibilityIdentifier("field-open")
            if !model.draft.openNetwork {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L.t("field.password")).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                    SecureField(L.t("field.password"), text: $model.draft.password, prompt: Text(L.t("field.personal")))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .fieldSurface()
                        .focused($focus, equals: "field-password")
                        .accessibilityLabel(L.t("field.password"))
                        .accessibilityIdentifier("field-password")
                }
            }
        case .contact:
            field("field.name", value: $model.draft.name, id: "field-name")
            field("field.phone", value: $model.draft.phone, id: "field-phone", keyboard: .phonePad)
            field("field.email", value: $model.draft.email, id: "field-email", keyboard: .emailAddress)
            Text(L.t("field.contactHint")).font(.caption).foregroundStyle(Palette.muted)
        }
    }

    private func field(_ label: String, hint: String? = nil, value: Binding<String>, id: String,
                       keyboard: UIKeyboardType = .default) -> some View {
        let title = L.t(label)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            TextField(title, text: value, prompt: Text(hint ?? title))
                .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
                .fieldSurface()
                .focused($focus, equals: id)
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
                .onSubmit {
                    if id == "field-link" {
                        focus = nil
                        Task { await model.create() }
                    }
                }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L.t("history.recent")).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if !model.cards.isEmpty {
                    Button(L.t("history.all")) { model.modal = .history }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .accessibilityIdentifier("home-history")
                }
            }
            if model.cards.isEmpty {
                Text(L.t("history.empty"))
                    .font(.footnote).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).surface()
                    .accessibilityIdentifier("history-empty")
            } else {
                CardRows(cards: Array(model.cards.prefix(2)), model: model, idPrefix: "recent")
            }
        }
    }
}

struct CardRows: View {
    let cards: [Card]
    @ObservedObject var model: AppModel
    let idPrefix: String

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                if index != 0 { Divider().overlay(Palette.line) }
                HStack(spacing: 8) {
                    Button {
                        Task { await model.show(card) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: card.kind.icon)
                                .foregroundStyle(Palette.brand)
                                .frame(width: 38, height: 38)
                                .background(Palette.tint, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.displayTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(card.kind.isSensitive ? L.f("history.sensitiveKind", card.kind.label) : card.kind.label)
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(idPrefix)-card-\(index)")
                    .disabled(model.busy || model.sharing)
                    IconAction(icon: "square.and.arrow.up", title: L.f("history.share", card.displayTitle),
                               id: "\(idPrefix)-share-\(index)", background: Palette.screen) {
                        Task { await model.sharePNG(card) }
                    }
                    .disabled(model.busy || model.sharing)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
            }
        }
        .surface()
    }
}
