import StoreKit
import SwiftUI

@main
struct QRCardApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.light)
                .tint(Palette.brand)
                .foregroundStyle(Palette.ink)
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var openedFile: URL?

    private var sheetShown: Binding<Bool> {
        Binding(get: { model.modal != nil }, set: { if !$0 { model.modal = nil } })
    }

    var body: some View {
        Group {
            if let preview = model.detail {
                ResultView(model: model, preview: preview)
            } else {
                HomeView(model: model)
            }
        }
        .sheet(isPresented: sheetShown) {
            ModalView(model: model)
                .foregroundStyle(Palette.ink)
                .tint(Palette.brand)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(model.busy || model.sharing)
                .modifier(MessageAlert(model: model, inSheet: true))
        }
        .modifier(MessageAlert(model: model, inSheet: false))
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.start() }
        }
        .onOpenURL { openedFile = $0 }
        .onChange(of: fileToImport, initial: true) { _, file in
            guard let file else { return }
            openedFile = nil
            Task { await model.receiveFile(file) }
        }
        .task(id: canReview) {
            guard canReview else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            if await model.markReviewAttempted(), scenePhase == .active { requestReview() }
        }
    }

    private var fileToImport: URL? {
        model.ready && !model.busy && !model.sharing ? openedFile : nil
    }

    private var canReview: Bool {
        model.reviewCandidate && openedFile == nil && scenePhase == .active
    }
}

struct MessageAlert: ViewModifier {
    @ObservedObject var model: AppModel
    let inSheet: Bool

    func body(content: Content) -> some View {
        content.alert(L.t("app.name"), isPresented: Binding(
            get: { model.alert != nil && (model.modal != nil) == inSheet },
            set: { if !$0 { model.alert = nil } }
        )) {
            Button(L.t("action.ok")) { model.alert = nil }
                .accessibilityIdentifier("message-ok")
        } message: {
            Text(model.alert ?? "")
        }
    }
}
