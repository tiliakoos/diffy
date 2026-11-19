import CoreGraphics
import SwiftUI
import DiffyCore
import Foundation

/// Live drag-to-reorder for the popover's platters.
///
/// Built from a snapshot of every platter's frame (in scroll-content coordinates) when the drag
/// starts. The grabbed sibling, with its children if it's a top-level row, follows the pointer;
/// the siblings it passes slide out of its way. Everything is a visual offset: nothing changes
/// height, so the `NSPopover` never resizes mid-drag. The store is only touched on drop.
struct PlatterReorder: Equatable {
    /// The grabbed row.
    let id: UUID
    /// The rows it reorders among, in display order: a group's top-level rows, or one parent's children.
    let siblings: [UUID]
    /// Each sibling and the rows that move with it (a top-level row carries its children).
    let units: [UUID: [UUID]]
    /// Each sibling unit's vertical extent when the drag started.
    let spans: [UUID: ClosedRange<CGFloat>]
    let spacing: CGFloat
    let startScrollOffset: CGFloat
    var pointerTranslation: CGFloat = 0
    /// Set when dropping or cancelling, so the grabbed rows animate into their resting place.
    var settledTranslation: CGFloat?

    /// Starts a drag of `id` among `rows` (the popover's visible rows, each top-level row
    /// followed by its children). Nil when the row has nowhere to go or a frame is missing.
    init?(id: UUID, rows: [RepositoryConfig], frames: [UUID: CGRect], spacing: CGFloat, scrollOffset: CGFloat) {
        guard let grabbed = rows.first(where: { $0.id == id }) else { return nil }
        let siblings = rows.filter { $0.parentRepositoryID == grabbed.parentRepositoryID }.map(\.id)
        guard siblings.count > 1 else { return nil }

        var units: [UUID: [UUID]] = [:]
        var spans: [UUID: ClosedRange<CGFloat>] = [:]
        for sibling in siblings {
            let members = grabbed.parentRepositoryID == nil
                ? [sibling] + rows.filter { $0.parentRepositoryID == sibling }.map(\.id)
                : [sibling]
            let memberFrames = members.compactMap { frames[$0] }
            guard memberFrames.count == members.count,
                  let top = memberFrames.map(\.minY).min(),
                  let bottom = memberFrames.map(\.maxY).max()
            else { return nil }
            units[sibling] = members
            spans[sibling] = top...bottom
        }

        self.id = id
        self.siblings = siblings
        self.units = units
        self.spans = spans
        self.spacing = spacing
        self.startScrollOffset = scrollOffset
    }

    var originalIndex: Int { siblings.firstIndex(of: id) ?? 0 }

    /// How far the grabbed rows sit from home, kept within the siblings' combined extent.
    func translation(scrollOffset: CGFloat) -> CGFloat {
        if let settledTranslation { return settledTranslation }
        guard let own = spans[id], let first = siblings.first.flatMap({ spans[$0] }),
              let last = siblings.last.flatMap({ spans[$0] })
        else { return 0 }
        let raw = pointerTranslation + scrollOffset - startScrollOffset
        return min(max(raw, first.lowerBound - own.lowerBound), last.upperBound - own.upperBound)
    }

    /// Where the grabbed sibling would land if dropped now. Moving up, it passes a sibling once
    /// its top edge crosses that sibling's middle; moving down, once its bottom edge does. Edges,
    /// not its own middle, so a tall family can still pass a short row at either end.
    func targetIndex(scrollOffset: CGFloat) -> Int {
        guard let own = spans[id] else { return originalIndex }
        let shift = translation(scrollOffset: scrollOffset)
        let top = own.lowerBound + shift
        let bottom = own.upperBound + shift
        var target = originalIndex
        for (index, sibling) in siblings.enumerated() where sibling != id {
            guard let span = spans[sibling] else { continue }
            let middle = (span.lowerBound + span.upperBound) / 2
            if index < originalIndex, top < middle { target = min(target, index) }
            if index > originalIndex, bottom > middle { target = max(target, index) }
        }
        return target
    }

    /// Vertical offset to draw `row` at; zero for rows outside this sibling set.
    func offset(for row: UUID, scrollOffset: CGFloat) -> CGFloat {
        guard let owner = units.first(where: { $0.value.contains(row) })?.key else { return 0 }
        if owner == id { return translation(scrollOffset: scrollOffset) }
        guard let index = siblings.firstIndex(of: owner), let own = spans[id] else { return 0 }
        let target = targetIndex(scrollOffset: scrollOffset)
        let shift = own.upperBound - own.lowerBound + spacing
        if index > originalIndex, index <= target { return -shift }
        if index >= target, index < originalIndex { return shift }
        return 0
    }

    func isMoving(_ row: UUID) -> Bool {
        units[id]?.contains(row) ?? false
    }

    /// The translation that puts the grabbed rows exactly in the slot at `target`.
    func restingTranslation(for target: Int) -> CGFloat {
        let height: (UUID) -> CGFloat = { sibling in
            guard let span = self.spans[sibling] else { return 0 }
            return span.upperBound - span.lowerBound + self.spacing
        }
        if target > originalIndex {
            return siblings[(originalIndex + 1)...target].map(height).reduce(0, +)
        }
        if target < originalIndex {
            return -siblings[target..<originalIndex].map(height).reduce(0, +)
        }
        return 0
    }

    /// The siblings' new order after dropping at `target`.
    func order(droppingAt target: Int) -> [UUID] {
        var ids = siblings
        ids.remove(at: originalIndex)
        ids.insert(id, at: min(max(target, 0), ids.count))
        return ids
    }
}

/// The scroll view's position and size, as the drag needs them.
struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var viewport: CGFloat = 0
    var content: CGFloat = 0
}

/// Makes a platter's header the place to grab it: an open hand on hover, a closed one while
/// dragging, and the drag gesture. Clicks still reach the ⋯ menu; a drag needs 3 pt of travel.
struct ReorderHandle<DragGestureType: Gesture>: ViewModifier {
    let isEnabled: Bool
    let isDragging: Bool
    let gesture: DragGestureType
    let onHover: (Bool) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .onHover(perform: onHover)
                .pointerStyle(isDragging ? .grabActive : .grabIdle)
                .gesture(gesture)
        } else {
            content
        }
    }
}
