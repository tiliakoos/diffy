import AppKit
import DiffyCore

enum BadgeRenderer {
    static func image(
        added: Int,
        removed: Int,
        colors: DiffColors,
        badgeLabel: BadgeLabel? = nil,
        hasError: Bool = false,
        interface: Interface = .modern
    ) -> NSImage {
        switch interface {
        case .modern:
            modernImage(added: added, removed: removed, colors: colors, badgeLabel: badgeLabel, hasError: hasError)
        case .classic:
            classicImage(added: added, removed: removed, colors: colors, badgeLabel: badgeLabel, hasError: hasError)
        }
    }

    /// Grouped below 10,000; above, one decimal and a "k" so the item stays narrow.
    static func countText(_ count: Int) -> String {
        if count < 10_000 {
            return count.formatted(.number)
        }
        return (Double(count) / 1000).formatted(.number.precision(.fractionLength(0...1))) + "k"
    }

    /// `+1,108 / −170` with a true minus; the ± mark alone when clean. Counts are
    /// dynamic system green and red unless the group customized them. A group with a badge
    /// color gets it as a pill behind the text, with the ± and label in black or white,
    /// whichever reads on it. The image is drawn through a handler so it re-renders for the
    /// menu bar's current appearance.
    private static func modernImage(
        added: Int,
        removed: Int,
        colors: DiffColors,
        badgeLabel: BadgeLabel?,
        hasError: Bool
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let additionColor = colors.hasSystemDiffColors ? NSColor.systemGreen : AppColor.nsColor(hex: colors.additionHex) ?? .systemGreen
        let removalColor = colors.hasSystemDiffColors ? NSColor.systemRed : AppColor.nsColor(hex: colors.removalHex) ?? .systemRed
        let pill = colors.badgeBackgroundHex.flatMap(AppColor.nsColor(hex:))
        let markColor = pill.map(AppColor.contrastingTextColor(on:)) ?? .labelColor
        let dimColor = pill == nil ? NSColor.secondaryLabelColor : markColor.withAlphaComponent(0.75)

        let text = NSMutableAttributedString()
        let label = badgeLabel?.text.trimmingCharacters(in: .whitespaces) ?? ""
        let labelText = NSAttributedString(
            string: label,
            attributes: [.foregroundColor: dimColor, .font: labelFont]
        )
        let space = NSAttributedString(string: " ", attributes: [.font: font])

        if !label.isEmpty, badgeLabel?.position != .trailing {
            text.append(labelText)
            text.append(space)
        }

        if added == 0, removed == 0, !hasError {
            text.append(symbolAttachment("plusminus", color: markColor, font: font))
        } else {
            text.append(NSAttributedString(string: "+\(countText(added))", attributes: [.foregroundColor: additionColor, .font: font]))
            text.append(NSAttributedString(string: " / ", attributes: [.foregroundColor: dimColor, .font: font]))
            text.append(NSAttributedString(string: "\u{2212}\(countText(removed))", attributes: [.foregroundColor: removalColor, .font: font]))
        }

        if hasError {
            text.append(space)
            text.append(symbolAttachment("exclamationmark.triangle.fill", color: .systemOrange, font: font))
        }

        if !label.isEmpty, badgeLabel?.position == .trailing {
            text.append(space)
            text.append(labelText)
        }

        let horizontalPadding: CGFloat = pill == nil ? 1 : 8
        let verticalPadding: CGFloat = pill == nil ? 0 : 3
        let textSize = text.size()
        let size = NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: max(18, ceil(textSize.height) + verticalPadding * 2)
        )
        let drawn = NSAttributedString(attributedString: text)
        let image = NSImage(size: size, flipped: false) { rect in
            if let pill {
                let capsule = rect.insetBy(dx: 0.5, dy: 1)
                pill.withAlphaComponent(0.82).setFill()
                NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
            }
            drawn.draw(at: NSPoint(x: horizontalPadding, y: floor((rect.height - textSize.height) / 2)))
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func symbolAttachment(_ name: String, color: NSColor, font: NSFont) -> NSAttributedString {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
            .applying(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = symbol
        let yOffset = (font.capHeight - symbol.size.height) / 2
        attachment.bounds = CGRect(x: 0, y: yOffset, width: symbol.size.width, height: symbol.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func classicImage(
        added: Int,
        removed: Int,
        colors: DiffColors,
        badgeLabel: BadgeLabel?,
        hasError: Bool
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let additionColor = AppColor.nsColor(hex: colors.additionHex) ?? .systemGreen
        let removalColor = AppColor.nsColor(hex: colors.removalHex) ?? .systemRed
        let separatorColor = NSColor.secondaryLabelColor

        let countsText = NSMutableAttributedString()
        countsText.append(NSAttributedString(string: "+\(added)", attributes: [.foregroundColor: additionColor, .font: font]))
        countsText.append(NSAttributedString(string: " / ", attributes: [.foregroundColor: separatorColor, .font: font]))
        countsText.append(NSAttributedString(string: "-\(removed)", attributes: [.foregroundColor: removalColor, .font: font]))

        if hasError {
            let symbolConfig = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
                .applying(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .semibold))
            if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "error")?
                .withSymbolConfiguration(symbolConfig) {
                let attachment = NSTextAttachment()
                attachment.image = symbol
                let yOffset = (font.capHeight - symbol.size.height) / 2
                attachment.bounds = CGRect(x: 0, y: yOffset, width: symbol.size.width, height: symbol.size.height)
                countsText.append(NSAttributedString(string: " ", attributes: [.font: font]))
                countsText.append(NSAttributedString(attachment: attachment))
            }
        }

        let countsSize = countsText.size()
        let horizontalPadding: CGFloat = colors.badgeBackgroundHex == nil ? 1 : 8
        let verticalPadding: CGFloat = colors.badgeBackgroundHex == nil ? 0 : 3

        let labelText: NSAttributedString? = badgeLabel.flatMap { label -> NSAttributedString? in
            let trimmed = label.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let labelFont = NSFont.monospacedDigitSystemFont(
                ofSize: max(NSFont.smallSystemFontSize, NSFont.systemFontSize - 2),
                weight: .semibold
            )
            return NSAttributedString(
                string: trimmed,
                attributes: [.foregroundColor: separatorColor, .font: labelFont]
            )
        }

        let labelSize = labelText?.size() ?? .zero
        let labelGap: CGFloat = 3

        var width = countsSize.width
        var height = countsSize.height
        if labelText != nil, let position = badgeLabel?.position {
            switch position {
            case .leading, .trailing:
                width += labelSize.width + labelGap
            case .above, .below:
                width = max(width, labelSize.width)
                height = countsSize.height + labelSize.height + labelGap
            }
        }

        let size = NSSize(
            width: ceil(width + horizontalPadding * 2),
            height: ceil(max(18, height + verticalPadding * 2))
        )

        let image = NSImage(size: size)
        image.lockFocus()

        if let backgroundHex = colors.badgeBackgroundHex, let background = AppColor.nsColor(hex: backgroundHex) {
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            background.withAlphaComponent(0.82).setFill()
            path.fill()
        }

        let position = badgeLabel?.position
        if let labelText, let position {
            switch position {
            case .leading:
                let labelRect = NSRect(
                    x: horizontalPadding,
                    y: floor((size.height - labelSize.height) / 2),
                    width: labelSize.width,
                    height: labelSize.height
                )
                labelText.draw(in: labelRect)
                let countsRect = NSRect(
                    x: horizontalPadding + labelSize.width + labelGap,
                    y: floor((size.height - countsSize.height) / 2),
                    width: countsSize.width,
                    height: countsSize.height
                )
                countsText.draw(in: countsRect)

            case .trailing:
                let countsRect = NSRect(
                    x: horizontalPadding,
                    y: floor((size.height - countsSize.height) / 2),
                    width: countsSize.width,
                    height: countsSize.height
                )
                countsText.draw(in: countsRect)
                let labelRect = NSRect(
                    x: horizontalPadding + countsSize.width + labelGap,
                    y: floor((size.height - labelSize.height) / 2),
                    width: labelSize.width,
                    height: labelSize.height
                )
                labelText.draw(in: labelRect)

            case .above:
                let totalStackHeight = labelSize.height + labelGap + countsSize.height
                let stackTop = floor((size.height - totalStackHeight) / 2)
                let labelY = size.height - stackTop - labelSize.height
                let countsY = labelY - labelGap - countsSize.height
                let labelRect = NSRect(
                    x: floor((size.width - labelSize.width) / 2),
                    y: labelY,
                    width: labelSize.width,
                    height: labelSize.height
                )
                let countsRect = NSRect(
                    x: floor((size.width - countsSize.width) / 2),
                    y: countsY,
                    width: countsSize.width,
                    height: countsSize.height
                )
                labelText.draw(in: labelRect)
                countsText.draw(in: countsRect)

            case .below:
                let totalStackHeight = countsSize.height + labelGap + labelSize.height
                let stackTop = floor((size.height - totalStackHeight) / 2)
                let countsY = size.height - stackTop - countsSize.height
                let labelY = countsY - labelGap - labelSize.height
                let countsRect = NSRect(
                    x: floor((size.width - countsSize.width) / 2),
                    y: countsY,
                    width: countsSize.width,
                    height: countsSize.height
                )
                let labelRect = NSRect(
                    x: floor((size.width - labelSize.width) / 2),
                    y: labelY,
                    width: labelSize.width,
                    height: labelSize.height
                )
                countsText.draw(in: countsRect)
                labelText.draw(in: labelRect)
            }
        } else {
            let countsRect = NSRect(
                x: horizontalPadding,
                y: floor((size.height - countsSize.height) / 2),
                width: countsSize.width,
                height: countsSize.height
            )
            countsText.draw(in: countsRect)
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
