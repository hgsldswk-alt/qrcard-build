import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    static let environment = ProcessInfo.processInfo.environment

    static var testing: Bool {
        #if DEBUG
        arguments.contains("-ui-testing")
        #else
        false
        #endif
    }

    static var isFree: Bool {
        freePeriod && !(testing && !Set(arguments).isDisjoint(with: ["-paid-mode", "-paywall", "-expired"]))
    }

    static func fixture(_ flag: String) -> Bool { testing && arguments.contains(flag) }

    static var downloadURL: URL? {
        guard !testing else { return nil }
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(id)")
    }
}
