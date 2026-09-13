import AppKit
import Foundation

struct ScreenshotHotkeyChord: Equatable, Codable, Sendable {
    var keyCode: UInt16
    /// Device-independent modifier raw value (NSEvent.ModifierFlags).
    var modifiersRaw: UInt

    static let `default` = ScreenshotHotkeyChord(
        keyCode: 0x16, // ANSI 6
        modifiersRaw: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
            .intersection(.deviceIndependentFlagsMask)
    }

    var displayString: String {
        var parts: [String] = []
        let flags = modifierFlags
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyName(keyCode))
        return parts.joined()
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(
            keyCode: event.keyCode,
            modifiersRaw: event.modifierFlags.rawValue
        )
    }

    func matches(keyCode: UInt16, modifiersRaw: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiersRaw)
            .intersection(.deviceIndependentFlagsMask)
        return flags == modifierFlags && keyCode == self.keyCode
    }

    private static func keyName(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
            0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
            0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1",
            0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]",
            0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I", 0x23: "P", 0x25: "L",
            0x26: "J", 0x27: "'", 0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",",
            0x2C: "/", 0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
            0x24: "↩", 0x30: "⇥", 0x31: "空格", 0x33: "⌫", 0x35: "⎋",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5",
            0x61: "F6", 0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10",
            0x67: "F11", 0x6F: "F12",
        ]
        return map[keyCode] ?? "Key\(keyCode)"
    }
}
