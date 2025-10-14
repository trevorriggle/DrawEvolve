//
//  CrashReporter.swift
//  DrawEvolve
//
//  Crash and error reporting for beta debugging.
//

import Foundation
import OSLog

class CrashReporter {
    static let shared = CrashReporter()

    private let logger = Logger(subsystem: "com.drawevolve.app", category: "CrashReporter")
    private let crashLogKey = "crashLogs"
    private let maxCrashLogs = 50

    private init() {
        setupCrashHandling()
    }

    // MARK: - Setup

    private func setupCrashHandling() {
        // Set up uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.logCrash(
                type: "UncaughtException",
                message: exception.name.rawValue,
                stack: exception.callStackSymbols.joined(separator: "\n"),
                userInfo: exception.userInfo
            )
        }

        // Log app version and device info on init
        logAppInfo()
    }

    // MARK: - Logging

    func logCrash(type: String, message: String, stack: String? = nil, userInfo: [AnyHashable: Any]? = nil) {
        let crashReport: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": type,
            "message": message,
            "stack": stack ?? "No stack trace available",
            "userInfo": userInfo?.description ?? "No additional info",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "deviceModel": UIDevice.current.model,
            "userId": AnonymousUserManager.shared.userID
        ]

        // Log to console
        logger.error("🔴 CRASH: \(type) - \(message)")
        if let stack = stack {
            logger.error("Stack: \(stack)")
        }

        // Save to UserDefaults for persistence
        saveCrashReport(crashReport)

        // In production, this is where you'd send to a crash reporting service
        // For now, we just log locally
    }

    func logError(_ error: Error, context: String, file: String = #file, function: String = #function, line: Int = #line) {
        let errorReport: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": "Error",
            "message": error.localizedDescription,
            "context": context,
            "file": (file as NSString).lastPathComponent,
            "function": function,
            "line": line,
            "userId": AnonymousUserManager.shared.userID
        ]

        logger.error("⚠️ ERROR in \(context): \(error.localizedDescription) [\((file as NSString).lastPathComponent):\(line)]")

        saveCrashReport(errorReport)
    }

    func logWarning(_ message: String, context: String, file: String = #file, function: String = #function, line: Int = #line) {
        let warningReport: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": "Warning",
            "message": message,
            "context": context,
            "file": (file as NSString).lastPathComponent,
            "function": function,
            "line": line,
            "userId": AnonymousUserManager.shared.userID
        ]

        logger.warning("⚠️ WARNING in \(context): \(message) [\((file as NSString).lastPathComponent):\(line)]")

        saveCrashReport(warningReport)
    }

    // MARK: - Persistence

    private func saveCrashReport(_ report: [String: Any]) {
        var existingLogs = getCrashLogs()
        existingLogs.append(report)

        // Keep only the most recent logs
        if existingLogs.count > maxCrashLogs {
            existingLogs = Array(existingLogs.suffix(maxCrashLogs))
        }

        if let data = try? JSONSerialization.data(withJSONObject: existingLogs) {
            UserDefaults.standard.set(data, forKey: crashLogKey)
        }
    }

    func getCrashLogs() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: crashLogKey),
              let logs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return logs
    }

    func clearCrashLogs() {
        UserDefaults.standard.removeObject(forKey: crashLogKey)
        logger.info("Crash logs cleared")
    }

    func getCrashLogsAsString() -> String {
        let logs = getCrashLogs()
        guard !logs.isEmpty else {
            return "No crash logs available"
        }

        var output = "=== CRASH LOGS (\(logs.count) entries) ===\n\n"

        for (index, log) in logs.enumerated() {
            output += "[\(index + 1)] "
            output += "\(log["timestamp"] ?? "Unknown time")\n"
            output += "Type: \(log["type"] ?? "Unknown")\n"
            output += "Message: \(log["message"] ?? "No message")\n"

            if let context = log["context"] {
                output += "Context: \(context)\n"
            }

            if let file = log["file"], let line = log["line"] {
                output += "Location: \(file):\(line)\n"
            }

            if let stack = log["stack"] as? String, stack != "No stack trace available" {
                output += "Stack:\n\(stack)\n"
            }

            output += "\n---\n\n"
        }

        return output
    }

    // MARK: - App Info

    private func logAppInfo() {
        logger.info("📱 App Started")
        logger.info("Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
        logger.info("Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")")
        logger.info("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        logger.info("Device: \(UIDevice.current.model)")
        logger.info("User ID: \(AnonymousUserManager.shared.userID)")
    }

    func getAppInfo() -> [String: String] {
        return [
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown",
            "buildNumber": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "deviceModel": UIDevice.current.model,
            "userId": AnonymousUserManager.shared.userID
        ]
    }
}

// MARK: - Convenience Extensions

extension Error {
    func log(context: String, file: String = #file, function: String = #function, line: Int = #line) {
        CrashReporter.shared.logError(self, context: context, file: file, function: function, line: line)
    }
}
