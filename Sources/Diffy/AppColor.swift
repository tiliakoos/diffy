import AppKit
import DiffyCore
import SwiftUI

extension DiffColors {
    /// System green and red unless the group customized its colors; the system ones adapt to
    /// dark mode and Increase Contrast, fixed hex values don't.
    var additionColor: Color {
        self == .default ? .green : AppColor.swiftUIColor(hex: additionHex)
    }

    var removalColor: Color {
        self == .default ? .red : AppColor.swiftUIColor(hex: removalHex)
    }
}

enum AppColor {
    static func swiftUIColor(hex: String) -> Color {
        Color(nsColor: nsColor(hex: hex) ?? .labelColor)
    }

    static func nsColor(hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let integer = UInt32(value, radix: 16) else {
            return nil
        }

        let red = CGFloat((integer & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((integer & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(integer & 0x0000FF) / 255.0
        return NSColor(red: red, green: green, blue: blue, alpha: 1)
    }

    static func hex(_ color: Color) -> String {
        hex(NSColor(color))
    }

    static func hex(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int(round(converted.redComponent * 255))
        let green = Int(round(converted.greenComponent * 255))
        let blue = Int(round(converted.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
