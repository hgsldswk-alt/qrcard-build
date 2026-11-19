import Foundation

enum CardKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case link, text, wifi, contact

    var id: String { rawValue }
    var isSensitive: Bool { self == .wifi || self == .contact }

    var label: String {
        switch self {
        case .link: L.t("kind.link")
        case .text: L.t("kind.text")
        case .wifi: L.t("kind.wifi")
        case .contact: L.t("kind.contact")
        }
    }

    var qrLabel: String {
        switch self {
        case .link: L.t("qr.link")
        case .text: L.t("qr.text")
        case .wifi: L.t("qr.wifi")
        case .contact: L.t("qr.contact")
        }
    }

    var icon: String {
        switch self {
        case .link: "link"
        case .text: "text.alignleft"
        case .wifi: "wifi"
        case .contact: "person.crop.rectangle"
        }
    }
}

enum CardLayout: String, Codable, Sendable {
    case standard
}

struct CardDraft: Sendable {
    var link = ""
    var text = ""
    var ssid = ""
    var password = ""
    var openNetwork = false
    var name = ""
    var phone = ""
    var email = ""

    func encode(_ kind: CardKind) throws -> String {
        let payload: String
        switch kind {
        case .link:
            let value = link.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.contains(where: { $0.isWhitespace || $0 == "\\" }),
                  let address = URL(string: value, encodingInvalidCharacters: false),
                  let url = URLComponents(url: address, resolvingAgainstBaseURL: false),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw CardError.invalidLink
            }
            payload = value
        case .text:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CardError.emptyText }
            payload = text
        case .wifi:
            guard !ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !ssid.contains(where: \.isNewline) else { throw CardError.invalidSSID }
            guard openNetwork || (!password.isEmpty && !password.contains(where: \.isNewline)) else {
                throw CardError.invalidPassword
            }
            let passwordField = openNetwork ? "" : "P:\(Self.escapeWiFi(password));"
            payload = "WIFI:T:\(openNetwork ? "nopass" : "WPA");S:\(Self.escapeWiFi(ssid));\(passwordField);"
        case .contact:
            let contactName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let contactPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let contactEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contactName.isEmpty, !contactPhone.isEmpty || !contactEmail.isEmpty else {
                throw CardError.invalidContact
            }
            let escapedName = Self.escapeVCard(contactName)
            var lines = ["BEGIN:VCARD", "VERSION:3.0", "N:\(escapedName);;;;", "FN:\(escapedName)"]
            if !contactPhone.isEmpty { lines.append("TEL:\(Self.escapeVCard(contactPhone))") }
            if !contactEmail.isEmpty { lines.append("EMAIL:\(Self.escapeVCard(contactEmail))") }
            lines.append("END:VCARD")
            payload = lines.map(Self.foldVCardLine).joined(separator: "\r\n") + "\r\n"
        }
        guard payload.utf8.count <= 512 else { throw CardError.tooLarge }
        return payload
    }

    private static func escapeWiFi(_ value: String) -> String {
        var escaped = ""
        for character in value {
            if "\\;,\":".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private static func escapeVCard(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
    }

    private static func foldVCardLine(_ line: String) -> String {
        var result = ""
        var bytes = 0
        for scalar in line.unicodeScalars {
            let length = String(scalar).utf8.count
            if bytes + length > 75 {
                result += "\r\n "
                bytes = 1
            }
            result.unicodeScalars.append(scalar)
            bytes += length
        }
        return result
    }

    mutating func replaceFields(for kind: CardKind, with source: Self) {
        switch kind {
        case .link: link = source.link
        case .text: text = source.text
        case .wifi:
            ssid = source.ssid
            password = source.password
            openNetwork = source.openNetwork
        case .contact:
            name = source.name
            phone = source.phone
            email = source.email
        }
    }
}

struct Card: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var version = 1
    let kind: CardKind
    let payload: String
    var title: String?
    let createdAt: Date
    let layout: CardLayout

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        switch kind {
        case .link: return URLComponents(string: payload)?.host ?? kind.label
        case .text:
            return payload.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }.map { String($0.prefix(60)) } ?? kind.label
        case .wifi, .contact: return kind.label
        }
    }

    var publicContent: String? { kind.isSensitive ? nil : payload }

    func matches(_ query: String) -> Bool {
        query.isEmpty || displayTitle.localizedStandardContains(query) ||
            kind.label.localizedStandardContains(query) || publicContent?.localizedStandardContains(query) == true
    }

    func draftForCopy() -> CardDraft {
        switch kind {
        case .link: return CardDraft(link: payload)
        case .text: return CardDraft(text: payload)
        case .wifi:
            let fields = Self.wifiFields(payload)
            return CardDraft(ssid: fields["S"] ?? "", password: fields["P"] ?? "", openNetwork: fields["T"] == "nopass")
        case .contact:
            let unfolded = payload.replacingOccurrences(of: "\r\n ", with: "")
            var draft = CardDraft()
            for line in unfolded.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "FN": draft.name = Self.unescape(parts[1], vCard: true)
                case "TEL": draft.phone = Self.unescape(parts[1], vCard: true)
                case "EMAIL": draft.email = Self.unescape(parts[1], vCard: true)
                default: break
                }
            }
            return draft
        }
    }

    private static func wifiFields(_ payload: String) -> [String: String] {
        var fields: [String: String] = [:]
        var field = ""
        var escaped = false
        for character in payload.dropFirst(5) {
            if character == ";" && !escaped {
                let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 { fields[String(parts[0])] = unescape(parts[1], vCard: false) }
                field = ""
            } else {
                field.append(character)
            }
            escaped = character == "\\" && !escaped
        }
        return fields
    }

    private static func unescape(_ field: Substring, vCard: Bool) -> String {
        var result = ""
        var escaped = false
        for character in field {
            if escaped {
                result.append(vCard && character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}

enum CardError: Error, Equatable {
    case invalidLink, emptyText, invalidSSID, invalidPassword, invalidContact, tooLarge, render, importFormat

    var message: String {
        switch self {
        case .invalidLink: L.t("error.link")
        case .emptyText: L.t("error.text")
        case .invalidSSID: L.t("error.ssid")
        case .invalidPassword: L.t("error.password")
        case .invalidContact: L.t("error.contact")
        case .tooLarge: L.t("error.length")
        case .render: L.t("error.render")
        case .importFormat: L.t("error.import")
        }
    }
}
