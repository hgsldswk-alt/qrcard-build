import Foundation
import Security

struct Entitlement: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 30 * 86_400

    var firstOpen: Date
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false
    var lastSeen: Date

    init(firstOpen: Date = Date()) {
        self.firstOpen = firstOpen
        self.lastSeen = firstOpen
    }

    var trialStart: Date { proStartedAt ?? firstOpen }
    var trialEnd: Date { trialStart.addingTimeInterval(Self.duration) }

    mutating func enterPaidMode(at now: Date, restoredTrial: Date? = nil) {
        let localStart = proStartedAt ?? now
        proStartedAt = min(localStart, restoredTrial ?? localStart)
        lastSeen = max(lastSeen, now)
    }

    mutating func applyTrial(_ date: Date) {
        trialClaimedAt = min(trialClaimedAt ?? date, date)
        let localStart = proStartedAt ?? firstOpen
        proStartedAt = min(localStart, date)
    }

    func hasPro(at now: Date, free: Bool = Launch.isFree) -> Bool {
        if free || purchasedPro { return true }
        let effectiveNow = max(now, lastSeen)
        return effectiveNow >= trialStart && effectiveNow < trialEnd
    }

    func canClaimTrial(at now: Date) -> Bool {
        !purchasedPro && trialClaimedAt == nil && hasPro(at: now, free: false)
    }
}

actor EntitlementKeychain {
    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.hgsldswk.qrcard.entitlement",
            kSecAttrAccount as String: "local",
            kSecAttrSynchronizable as String: false
        ]
    }

    func read() throws -> Entitlement? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.status(status) }
        return try JSONDecoder().decode(Entitlement.self, from: data)
    }

    func save(_ value: Entitlement) throws {
        let data = try JSONEncoder().encode(value)
        let request = query()
        let attributes = [kSecValueData as String: data]
        let update = SecItemUpdate(request as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var item = request
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError.status(add) }
    }

    private enum KeychainError: Error { case status(OSStatus) }
}
