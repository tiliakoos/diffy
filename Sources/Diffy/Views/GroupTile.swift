import DiffyCore
import SwiftUI

/// The small colored square that identifies a group in the sidebar and popover: its menu-bar
/// label if it has one, else the first letter of its name. Color comes from the group, else a
/// palette slot by position so neighbouring groups differ.
struct GroupTile: View {
    let group: RepositoryGroup
    let index: Int
    var size: CGFloat = 18

    private static let palette = ["#0A7AFF", "#FF8D1A", "#2FB457", "#8E5BE8", "#2CA7B8", "#E0458A", "#8E8E93"]

    static func defaultColorHex(index: Int) -> String {
        palette[index % palette.count]
    }

    var body: some View {
        Text(letter)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(AppColor.swiftUIColor(hex: group.colorHex ?? Self.defaultColorHex(index: index)))
            )
    }

    private var letter: String {
        let source = group.badgeLabel?.text.trimmingCharacters(in: .whitespaces) ?? ""
        let text = source.isEmpty ? group.name.trimmingCharacters(in: .whitespaces) : source
        return text.first.map { String($0).uppercased() } ?? "D"
    }
}
