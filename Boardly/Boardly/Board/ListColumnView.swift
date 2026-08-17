import BoardlyKit
import SwiftUI
import UIKit

struct ListColumnView: View {
    let list: PlankaList
    let cards: [Card]
    let payload: BoardPayload
    let onCardTap: (Card) -> Void
    let onCreateCard: (String) -> Void
    var loadImage: ((URL) async -> Data?)?

    @State private var newCardName = ""
    @State private var isAddingCard = false
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header — list name + count pill, sitting directly on the paper.
            HStack(spacing: 8) {
                if let color = list.color {
                    Circle()
                        .fill(Color(plankaLabel: color))
                        .frame(width: 8, height: 8)
                }
                Text(list.name ?? "Untitled")
                    .font(.sans(16, .bold))
                    .foregroundStyle(Color.boardlyInk)
                    .lineLimit(1)
                Text("\(cards.count)")
                    .font(.sans(12, .bold))
                    .foregroundStyle(Color.boardlyTextTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.boardlyNeutralFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            // Cards + add-card — fills the column so its content scrolls all the way
            // to the bottom edge (under the tab bar), matching the list / grid modes.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(cards) { card in
                        Button { onCardTap(card) } label: {
                            CardRowView(
                                card: card,
                                taskLists: payload.taskLists(for: card),
                                tasks: payload.taskLists(for: card).flatMap { payload.tasks(for: $0) },
                                labels: payload.labels(for: card),
                                members: payload.members(for: card),
                                coverURL: payload.coverURL(for: card),
                                loadImage: loadImage)
                        }
                        .buttonStyle(.plain)
                    }

                    if isAddingCard {
                        TextField("Card title", text: $newCardName)
                            .font(.boardlyBody)
                            .padding(12)
                            .background(Color.boardlySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: 1))
                            .focused($addFieldFocused)
                            .onSubmit { submitNewCard() }
                    }

                    addCardButton
                }
                .padding(.bottom, 8)
                // Hard-stops the column at its end (see StopAtEnd); the top stays
                // free to rubber-band, which is what pull-to-refresh pulls on.
                .background(StopAtEnd())
            }
            // `.always`, so even a column with one card can be pulled to refresh.
            .scrollBounceBehavior(.always, axes: .vertical)
        }
    }

    private var addCardButton: some View {
        Button {
            isAddingCard = true
            addFieldFocused = true
        } label: {
            Label("Add a card", systemImage: "plus")
                .font(.sans(14, .semibold))
                .foregroundStyle(Color.boardlyTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
        }
    }

    /// Zero-size probe that clamps the hosting scroll view at its end, so a column can
    /// never be dragged past its last card — overscrolling there only slides the cards
    /// up behind the board header. Pulling *down* is left alone (pull-to-refresh), and
    /// a column shorter than the viewport therefore can't be dragged up at all.
    /// UIKit has no directional `bounces` flag, hence the offset clamp.
    private struct StopAtEnd: UIViewRepresentable {
        func makeUIView(context _: Context) -> UIView { Probe() }
        func updateUIView(_: UIView, context _: Context) {}

        private final class Probe: UIView {
            private var observation: NSKeyValueObservation?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard observation == nil, let scrollView = enclosingScrollView else { return }
                observation = scrollView.observe(\.contentOffset) { scrollView, _ in
                    let inset = scrollView.adjustedContentInset
                    let end = max(
                        -inset.top, // shorter than the viewport: the resting offset
                        scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
                    if scrollView.contentOffset.y > end {
                        scrollView.contentOffset.y = end
                    }
                }
            }

            private var enclosingScrollView: UIScrollView? {
                sequence(first: self as UIView) { $0.superview }
                    .compactMap { $0 as? UIScrollView }
                    .first
            }
        }
    }

    private func submitNewCard() {
        let name = newCardName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onCreateCard(name) }
        newCardName = ""
        isAddingCard = false
    }
}
