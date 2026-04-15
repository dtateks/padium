import Foundation
import os

// Centralised OSLog logger for the Padium subsystem.
enum PadiumLogger {
    static let gesture = Logger(subsystem: "com.padium", category: "gesture")
    static let shortcut = Logger(subsystem: "com.padium", category: "shortcut")
    static let permission = Logger(subsystem: "com.padium", category: "permission")
}
