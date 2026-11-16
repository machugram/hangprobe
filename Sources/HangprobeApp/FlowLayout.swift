import SwiftUI

/// Multi-line wrapping horizontal layout so pills, chips, and legends never squish vertically into deformed multi-line capsules.
struct FlowRow: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for (idx, row) in rows.enumerated() {
            widestRow = max(widestRow, row.width)
            totalHeight += row.height
            if idx > 0 { totalHeight += verticalSpacing }
        }
        return CGSize(width: proposal.width ?? widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = (row.height - item.size.height) * 0.5
                item.subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem {
        var subview: LayoutSubview
        var size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let clamped = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            let nextWidth = current.items.isEmpty ? clamped.width : (current.width + horizontalSpacing + clamped.width)

            if !current.items.isEmpty && nextWidth > maxWidth {
                rows.append(current)
                current = Row(items: [RowItem(subview: subview, size: clamped)], width: clamped.width, height: clamped.height)
            } else {
                current.items.append(RowItem(subview: subview, size: clamped))
                current.width = nextWidth
                current.height = max(current.height, clamped.height)
            }
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
