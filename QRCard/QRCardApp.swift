import StoreKit
import SwiftUI

@main
struct QRCardApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases()

    var body: some Scene {
        WindowGroup {
            RootView(model: model, purchases: purchases)
                .preferredColorScheme(.light)
                .tint(Palette.brand)
                .foregroundStyle(Palette.ink)
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var purchases: Purchases
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
            ModalView(model: model, purchases: purchases)
                .foregroundStyle(Palette.ink)
                .tint(Palette.brand)
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(model.busy || model.sharing || purchases.busy)
                .modifier(MessageAlert(model: model, inSheet: true))
        }
        .modifier(MessageAlert(model: model, inSheet: false))
        .task { await model.start() }
        .task {
            await purchases.start()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                if scenePhase == .active { await purchases.clockTick() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.start()
                if purchases.entitlement == nil { await purchases.start() }
                else { await purchases.refresh() }
                await purchases.clockTick()
            }
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
        model.reviewCandidate && openedFile == nil && purchases.hasPro && !purchases.busy && scenePhase == .active
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
