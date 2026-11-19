import StoreKit
import SwiftUI

@MainActor
final class Purchases: ObservableObject {
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var now = Date()
    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let storage = EntitlementKeychain()
    private let openedAt = Date()
    private var updates: Task<Void, Never>?
    private var loading = false
    private var refreshing = false

    private let proID = Bundle.main.object(forInfoDictionaryKey: "QRCardProProductID") as? String ?? "com.hgsldswk.qrcard.pro"
    private let trialID = Bundle.main.object(forInfoDictionaryKey: "QRCardTrialProductID") as? String ?? "com.hgsldswk.qrcard.trial"

    var hasPro: Bool { Launch.isFree || entitlement?.hasPro(at: Date()) == true }
    var price: String? {
        if Launch.fixture("-paywall") { return Launch.environment["QRC_TEST_PRICE"] }
        return product(proID)?.displayPrice
    }
    var hasTrialProduct: Bool { Launch.fixture("-paywall") || product(trialID) != nil }

    func start() async {
        guard entitlement == nil, !loading else { return }
        loading = true
        defer { loading = false }
        if Launch.testing {
            let first = Launch.fixture("-expired") ? openedAt.addingTimeInterval(-31 * 86_400) : openedAt
            var demo = Entitlement(firstOpen: first)
            demo.enterPaidMode(at: first)
            demo.purchasedPro = Launch.fixture("-pro")
            entitlement = demo
            now = Date()
            return
        }
        do {
            let saved = try await storage.read()
            var value = saved ?? Entitlement(firstOpen: openedAt)
            if !Launch.isFree {
                var restoredTrial: Date?
                if saved == nil,
                   case .verified(let trial)? = await StoreKit.Transaction.latest(for: trialID),
                   trial.revocationDate == nil {
                    restoredTrial = trial.originalPurchaseDate
                    value.trialClaimedAt = restoredTrial
                }
                value.enterPaidMode(at: openedAt, restoredTrial: restoredTrial)
            }
            try await storage.save(value)
            entitlement = value
        } catch {
            message = L.t("purchase.storage")
        }
        guard !Launch.isFree, entitlement != nil else { return }
        updates = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self, !Task.isCancelled else { break }
                if case .verified(let transaction) = result, await self.apply(transaction) {
                    await transaction.finish()
                }
            }
        }
        await refresh()
    }

    func clockTick() async {
        now = Date()
        guard var value = entitlement, now.timeIntervalSince(value.lastSeen) >= 30 else { return }
        value.lastSeen = now
        entitlement = value
        if !Launch.testing { try? await storage.save(value) }
    }

    func refresh() async {
        guard !Launch.testing, !Launch.isFree, entitlement != nil, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if case .verified(let transaction)? = await StoreKit.Transaction.latest(for: proID) {
            _ = await apply(transaction)
        }
        if case .verified(let transaction)? = await StoreKit.Transaction.latest(for: trialID) {
            _ = await apply(transaction)
        }
    }

    private func apply(_ transaction: StoreKit.Transaction) async -> Bool {
        guard var value = entitlement else { return false }
        switch transaction.productID {
        case proID:
            value.purchasedPro = transaction.revocationDate == nil && !transaction.isUpgraded
        case trialID:
            if transaction.revocationDate == nil { value.applyTrial(transaction.originalPurchaseDate) }
        default: return false
        }
        value.lastSeen = max(value.lastSeen, Date())
        entitlement = value
        do {
            try await storage.save(value)
            return true
        } catch {
            message = L.t("purchase.storage")
            return false
        }
    }

    private func product(_ id: String) -> Product? { products.first { $0.id == id } }

    func loadProducts() async {
        guard !Launch.testing, !Launch.isFree else { return }
        do {
            products = try await Product.products(for: [proID, trialID])
            if products.isEmpty { message = L.t("purchase.unavailable") }
        } catch {
            message = L.t("purchase.unavailable")
        }
    }

    func purchase(trial: Bool) async {
        guard !busy, !Launch.testing, !Launch.isFree,
              !trial || entitlement?.canClaimTrial(at: Date()) == true,
              let selected = product(trial ? trialID : proID) else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await selected.purchase() {
            case .success(.verified(let transaction)):
                if await apply(transaction) { await transaction.finish() }
            case .success(.unverified):
                message = L.t("purchase.unverified")
            case .pending:
                message = L.t("purchase.pending")
            case .userCancelled:
                break
            @unknown default:
                message = L.t("purchase.failed")
            }
        } catch {
            message = L.t("purchase.failed")
        }
    }

    func restore() async {
        guard !busy, !Launch.isFree, !Launch.testing else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            if entitlement == nil { await start() }
            var foundPro = false
            for await result in StoreKit.Transaction.currentEntitlements {
                guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
                if transaction.productID == proID && !transaction.isUpgraded { foundPro = true }
                if transaction.productID == trialID || transaction.productID == proID { _ = await apply(transaction) }
            }
            if !foundPro, var value = entitlement, value.purchasedPro {
                value.purchasedPro = false
                entitlement = value
                try await storage.save(value)
            }
            if message == nil { message = L.t(foundPro ? "purchase.restored" : "purchase.noPro") }
        } catch {
            message = L.t("purchase.restoreFailed")
        }
    }
}
