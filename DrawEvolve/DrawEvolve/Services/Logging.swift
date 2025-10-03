import Foundation
import os.log

enum Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.drawevolve.app"

    static let general = OSLog(subsystem: subsystem, category: "general")
    static let network = OSLog(subsystem: subsystem, category: "network")
    static let ui = OSLog(subsystem: subsystem, category: "ui")

    // MARK: - Logging Methods

    static func log(_ message: String, log: OSLog = .general, type: OSLogType = .default) {
        os_log("%{public}@", log: log, type: type, message)
    }

    static func error(_ message: String, log: OSLog = .general) {
        os_log("%{public}@", log: log, type: .error, message)
    }

    static func debug(_ message: String, log: OSLog = .general) {
        #if DEBUG
        os_log("%{public}@", log: log, type: .debug, message)
        #endif
    }

    static func info(_ message: String, log: OSLog = .general) {
        os_log("%{public}@", log: log, type: .info, message)
    }
}
