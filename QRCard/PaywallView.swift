import SwiftUI

struct PaywallView: View {
    @ObservedObject var purchases: Purchases
    let close: () -> Void

    var body: some View {
        SheetPage(title: L.t("purchase.title"), close: close) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L.t("purchase.feature"), systemImage: "printer").font(.title3.bold())
                Text(L.t("purchase.free")).font(.subheadline)
                Text(L.t("purchase.terms")).font(.subheadline).foregroundStyle(Palette.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface()
            if let value = purchases.entitlement {
                if value.purchasedPro {
                    Text(L.t("purchase.owned")).accessibilityIdentifier("purchase-owned")
                } else {
                    trialStatus(value)
                    if let price = purchases.price {
                        Button(L.f("purchase.buy", price)) { Task { await purchases.purchase(trial: false) } }
                            .buttonStyle(CardActionStyle(primary: true))
                            .accessibilityIdentifier("purchase-buy")
                    } else {
                        Text(L.t("purchase.unavailable")).foregroundStyle(Palette.muted)
                        Button(L.t("action.retry")) { Task { await purchases.loadProducts() } }
                            .buttonStyle(CardActionStyle())
                            .accessibilityIdentifier("purchase-retry")
                    }
                    if value.canClaimTrial(at: purchases.now), purchases.hasTrialProduct, purchases.price != nil {
                        Button(L.t("purchase.claim")) { Task { await purchases.purchase(trial: true) } }
                            .buttonStyle(CardActionStyle())
                            .accessibilityIdentifier("purchase-trial")
                    }
                }
            }
            Button(L.t("purchase.restore")) { Task { await purchases.restore() } }
                .buttonStyle(CardActionStyle())
                .accessibilityIdentifier("purchase-restore")
            if let message = purchases.message {
                Text(message).font(.footnote).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("purchase-message")
            }
        }
        .disabled(purchases.busy)
        .task { await purchases.loadProducts() }
    }

    private func trialStatus(_ value: Entitlement) -> some View {
        let date = value.trialEnd.formatted(date: .abbreviated, time: .shortened)
        let active = value.hasPro(at: purchases.now, free: false)
        return VStack(alignment: .leading, spacing: 5) {
            Text(L.f(active ? "purchase.ends" : "purchase.expired", date))
                .font(.subheadline.bold())
                .accessibilityIdentifier(active ? "purchase-active" : "purchase-expired")
            if active {
                Text(L.t("purchase.trialTerms")).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(color: Palette.tint)
    }
}
