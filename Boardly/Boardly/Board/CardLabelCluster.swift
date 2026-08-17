import BoardlyKit
import SwiftUI

/// A card's labels as compact colored chips, sized to sit in the top-right corner of a
/// card row — the same treatment in kanban, list and grid so a card reads the same way
/// whichever view it is seen in.
///
/// Past `maxVisible` the remainder collapses into a `+N` pill: a card with eight labels
/// must not crowd out its own title.
struct CardLabelCluster: View {
    let labels: [BoardlyKit.Label]
    var maxVisible = 3

    var body: some View {
        if !labels.isEmpty {
            HStack(spacing: 4) {
                ForEach(labels.prefix(maxVisible)) { label in
                    // A label name is server data — verbatim, never a catalog lookup.
                    Text(verbatim: label.name ?? "•")
                        .font(.sans(11, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Color(plankaLabel: label.color),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if labels.count > maxVisible {
                    Text("+\(labels.count - maxVisible)")
                        .font(.sans(11, .semibold))
                        .foregroundStyle(Color.boardlyTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Color.boardlyNeutralFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
        }
    }
}
