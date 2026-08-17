import BoardlyKit
import SwiftUI
import UIKit

/// How a board lays its cards out. The last mode the user picked is remembered
/// app-wide in UserDefaults under `boardly.boardViewMode`, so the next board opens
/// the way the previous one was left (`rawValue` is the persistence identifier —
/// never shown; `localizedName` is the copy).
enum BoardViewMode: String, CaseIterable {
    case kanban, list, grid

    var localizedName: LocalizedStringResource {
        switch self {
        case .kanban: "Kanban"
        case .list: "List"
        case .grid: "Grid"
        }
    }

    static let storageKey = "boardly.boardViewMode"
}

/// Thin wrapper that binds a board to its *shared*, ref-counted session. Opening
/// the same board from Projects and Search must not spin up two socket subscriptions
/// — both acquire the one `BoardViewModel` held by `BoardSessionStore` (realtime
/// starts on the first consumer, tears down on the last).
struct BoardView: View {
    let client: PlankaClient
    let boardId: String
    let boardName: String
    let projectName: String?
    /// When set (e.g. arriving from search), the board opens this card once loaded.
    let focusCardId: String?

    @Environment(BoardSessionStore.self) private var sessions
    @State private var lease: BoardSessionLease?

    init(
        client: PlankaClient,
        boardId: String,
        boardName: String,
        projectName: String? = nil,
        focusCardId: String? = nil)
    {
        self.client = client
        self.boardId = boardId
        self.boardName = boardName
        self.projectName = projectName
        self.focusCardId = focusCardId
    }

    var body: some View {
        Group {
            if let lease {
                BoardScreen(
                    viewModel: lease.viewModel,
                    boardName: boardName,
                    projectName: projectName,
                    focusCardId: focusCardId)
            } else {
                ZStack {
                    Color.boardlyBackground.ignoresSafeArea()
                    ProgressView().tint(.accentColor)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
        // Acquire once, on first appearance. The lease is held in @State and only
        // released when this view is destroyed (popped) — NOT on the transient
        // onDisappear a tab switch or a pushed card detail triggers. That keeps the
        // shared session (and its socket) alive across tab round-trips.
        .onAppear {
            if lease == nil {
                lease = BoardSessionLease(boardId: boardId, client: client, store: sessions)
            }
        }
    }
}

/// Holds a board session for as long as a `BoardView` is alive: `init` acquires,
/// `deinit` releases. Because it lives in the view's `@State`, `deinit` runs only
/// when the view is truly torn down (popped off the stack), so a tab switch — which
/// merely fires `onDisappear` — never releases the session.
@MainActor
private final class BoardSessionLease {
    let viewModel: BoardViewModel
    private let boardId: String
    private let store: BoardSessionStore

    init(boardId: String, client: PlankaClient, store: BoardSessionStore) {
        self.boardId = boardId
        self.store = store
        viewModel = store.acquire(boardId: boardId, client: client)
    }

    deinit {
        // deinit is nonisolated — hop back to the main actor to release.
        let store = store
        let boardId = boardId
        Task { @MainActor in store.release(boardId: boardId) }
    }
}

// MARK: - Board screen

private struct BoardScreen: View {
    let viewModel: BoardViewModel
    let boardName: String
    let projectName: String?
    /// When set (e.g. arriving from search), the board opens this card once loaded.
    let focusCardId: String?

    @State private var selectedCardId: SelectedCard?
    @State private var didFocusCard = false
    /// Shared across boards, so switching to List here opens the next board in List.
    @AppStorage(BoardViewMode.storageKey) private var modeRaw = BoardViewMode.kanban.rawValue
    /// The kanban column currently paged into view (nil until the first scroll).
    @State private var kanbanListId: String?
    @State private var showAddCard = false
    @State private var showCustomFieldsSheet = false
    @State private var showFilters = false
    @State private var filter = BoardFilter()
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var showMembers = false
    @State private var exportFile: ExportFile?
    @Environment(\.dismiss) private var dismiss

    /// Live board name — reflects a rename, falling back to the nav-time name.
    private var currentBoardName: String { viewModel.payload?.board.name ?? boardName }

    /// The remembered layout, falling back to Kanban if the stored value is unknown.
    private var mode: BoardViewMode { BoardViewMode(rawValue: modeRaw) ?? .kanban }

    /// Cards of a list after applying the active filter (members / labels / due).
    private func visibleCards(in list: PlankaList, payload: BoardPayload) -> [Card] {
        payload.cards(for: list).filter { filter.matches($0, in: payload) }
    }

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.boardlyBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    header
                    offlineBanner
                    viewSelector
                }
                .background(Color.boardlySurface.ignoresSafeArea(edges: .top))
                boardContent
            }

            if viewModel.payload != nil {
                fab
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if viewModel.payload == nil { await viewModel.load() }
            // The view may have been dismissed while the load was in flight; don't
            // resurrect realtime (or open a card) on a board the user already left.
            guard !Task.isCancelled else { return }
            // Deep-open the focused card at most once, and only if it still exists
            // on this board (it may have been deleted/moved since indexing).
            if let focusCardId, !didFocusCard,
               viewModel.payload?.cards.contains(where: { $0.id == focusCardId }) == true
            {
                didFocusCard = true
                selectedCardId = SelectedCard(id: focusCardId)
            }
            // Realtime is owned by the shared session (started on first acquire);
            // this screen only consumes it. Release happens via the view's lease
            // (see BoardView), not here — a tab switch must not tear it down.
        }
        .refreshable { await viewModel.load() }
        // Queued work has just landed (local ids became real ones), or the server refused
        // a mutation and the cached board is now wrong — either way, refetch.
        .task {
            let drained = NotificationCenter.default.notifications(named: .outboxDrained)
            for await _ in drained {
                await viewModel.load()
            }
        }
        .task {
            let refresh = NotificationCenter.default.notifications(named: .boardNeedsRefresh)
            for await notification in refresh {
                let boardId = notification.userInfo?["boardId"] as? String
                guard boardId == nil || boardId == viewModel.boardId else { continue }
                await viewModel.load()
            }
        }
        .navigationDestination(item: $selectedCardId) { selected in
            CardDetailView(cardId: selected.id, boardVM: viewModel)
        }
        .sheet(isPresented: $showFilters) {
            if let payload = viewModel.payload {
                BoardFiltersSheet(payload: payload, filter: $filter)
            }
        }
        .sheet(isPresented: $showCustomFieldsSheet) {
            BoardCustomFieldsSheet(boardVM: viewModel)
        }
        .sheet(isPresented: $showMembers) {
            BoardMembersSheet(boardVM: viewModel)
        }
        .sheet(isPresented: $showAddCard) {
            if let payload = viewModel.payload {
                NewCardSheet(lists: payload.sortedLists()) { list, title in
                    Task { await viewModel.createCard(in: list, name: title) }
                }
            }
        }
        .alert("Rename board", isPresented: $showRename) {
            TextField("Board name", text: $renameText)
            Button("Save") { Task { await viewModel.renameBoard(to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete board?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await viewModel.deleteBoard() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the board and all its cards.")
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }))
        {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .onChange(of: viewModel.boardDeleted) { _, deleted in
            if deleted { dismiss() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.boardlyInk)
            }
            .boardlyTapTarget("Back")
            VStack(alignment: .leading, spacing: 1) {
                Text(currentBoardName)
                    .font(.sans(20, .bold))
                    .foregroundStyle(Color.boardlyInk)
                    .lineLimit(1)
                if let projectName {
                    Text(projectName)
                        .font(.sans(12))
                        .foregroundStyle(Color.boardlyTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { showFilters = true } label: {
                Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .foregroundStyle(filter.isActive ? Color.accentColor : Color.boardlyTextSecondary)
            }
            .boardlyTapTarget("Filter and sort")
            Menu {
                Button { Task { await viewModel.load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    renameText = currentBoardName
                    showRename = true
                } label: {
                    Label("Rename board", systemImage: "pencil")
                }
                Button { showMembers = true } label: {
                    Label("Board members", systemImage: "person.2")
                }
                Button { showCustomFieldsSheet = true } label: {
                    Label("Custom Fields", systemImage: "square.grid.2x2")
                }
                Button {
                    exportFile = ExportFile(csv: viewModel.exportCSV(), name: currentBoardName)
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete board", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.boardlyTextSecondary)
            }
            .boardlyTapTarget("Board menu")
        }
        .font(.system(size: 17, weight: .semibold))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var viewSelector: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(BoardViewMode.allCases, id: \.self) { item in
                    let active = mode == item
                    Text(item.localizedName)
                        .font(.sans(14, .semibold))
                        .foregroundStyle(active ? Color.boardlyInk : Color.boardlyTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Color.boardlySurface : .clear))
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.15)) { modeRaw = item.rawValue }
                        }
                }
            }
            .padding(4)
            .background(Color.boardlySurfaceSecondary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Spacer(minLength: 8)
            if mode == .kanban, let lists = viewModel.payload?.sortedLists(), lists.count > 1 {
                kanbanPageIndicator(lists)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// Shown while the board is a cached copy, or while edits are still queued — the two
    /// facts a user needs to trust what they're looking at.
    @ViewBuilder
    private var offlineBanner: some View {
        if viewModel.isShowingCachedCopy || !viewModel.pendingIds.isEmpty {
            // Tappable: pull-to-refresh has to compete with the kanban's nested scroll
            // views for the gesture, so there is always a button that just works.
            Button { Task { await viewModel.load() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: viewModel.isShowingCachedCopy
                        ? "wifi.slash" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    if viewModel.isShowingCachedCopy, let cachedAt = viewModel.cachedAt {
                        Text("Offline copy from \(cachedAt.formatted(.relative(presentation: .named)))")
                    } else if viewModel.isShowingCachedCopy {
                        Text("Offline copy")
                    } else {
                        Text("\(viewModel.pendingIds.count) changes waiting to sync")
                    }
                    Spacer(minLength: 0)
                    Text("Retry")
                        .font(.sans(12, .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .font(.sans(12, .medium))
                .foregroundStyle(Color.boardlyTextSecondary)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
            .buttonStyle(.plain)
        }
    }

    /// One dot per kanban column, the current one elongated — the horizontal scroll
    /// pages column-by-column, so this is the only cue for position in a long board.
    private func kanbanPageIndicator(_ lists: [PlankaList]) -> some View {
        HStack(spacing: 5) {
            ForEach(lists) { list in
                let active = list.id == activeKanbanListId
                Button {
                    withAnimation(.snappy) { kanbanListId = list.id }
                } label: {
                    Capsule()
                        .fill(active ? Color.accentColor : Color.boardlyNeutralFill)
                        .frame(width: active ? 16 : 6, height: 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(list.name.map { Text(verbatim: $0) } ?? Text("Untitled"))
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
        .animation(.snappy(duration: 0.2), value: activeKanbanListId)
    }

    /// `kanbanListId` clamped to a list that still exists — a deleted or filtered-out
    /// column must not leave the indicator with nothing highlighted.
    private var activeKanbanListId: String? {
        let lists = viewModel.payload?.sortedLists() ?? []
        if let kanbanListId, lists.contains(where: { $0.id == kanbanListId }) { return kanbanListId }
        return lists.first?.id
    }

    // MARK: - Content

    @ViewBuilder
    private var boardContent: some View {
        if let payload = viewModel.payload {
            if payload.sortedLists().isEmpty {
                ContentUnavailableView(
                    "No lists",
                    systemImage: "rectangle.split.3x1",
                    description: Text("Add lists to this board from the web app."))
            } else {
                switch mode {
                case .kanban: kanbanMode(payload)
                case .list: listeMode(payload)
                case .grid: grilleMode(payload)
                }
            }
        } else if let error = viewModel.error {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
        } else {
            ProgressView().tint(.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Kanban

    private func kanbanMode(_ payload: BoardPayload) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(payload.sortedLists()) { list in
                    ListColumnView(
                        list: list,
                        cards: visibleCards(in: list, payload: payload),
                        payload: payload,
                        onCardTap: { selectedCardId = SelectedCard(id: $0.id) },
                        onCreateCard: { name in
                            Task { await viewModel.createCard(in: list, name: name) }
                        },
                        loadImage: { await viewModel.loadImage(url: $0) })
                        // One column per page: the container is already inset by
                        // safeAreaPadding, so the leftover inset shows a sliver of
                        // the neighbouring column as an affordance to swipe on.
                        .containerRelativeFrame(.horizontal, count: 1, span: 1, spacing: 0)
                }
            }
            .scrollTargetLayout()
            .padding(.top, 8)
            // Stretch the columns to the full viewport height so each column's card
            // list scrolls to the bottom edge (under the tab bar), like list / grid.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // safeAreaPadding, not .padding on the content: it insets the pages while
        // keeping each column aligned to the container for snapping.
        .safeAreaPadding(.horizontal, 20)
        .scrollTargetBehavior(DeliberateColumnPaging())
        .scrollPosition(id: $kanbanListId, anchor: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Liste

    private func listeMode(_ payload: BoardPayload) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(payload.sortedLists()) { list in
                    let cards = visibleCards(in: list, payload: payload)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(list.name ?? "Untitled")
                                .font(.sans(16, .bold))
                                .foregroundStyle(Color.boardlyInk)
                            Text("\(cards.count)")
                                .font(.mono(11, .medium))
                                .foregroundStyle(Color.boardlyTextSecondary)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.boardlySurfaceSecondary, in: Capsule())
                            Spacer(minLength: 0)
                        }
                        ForEach(cards) { card in
                            ListModeCardRow(
                                card: card,
                                tasks: payload.taskLists(for: card).flatMap { payload.tasks(for: $0) },
                                labels: payload.labels(for: card),
                                onTap: { selectedCardId = SelectedCard(id: card.id) },
                                onToggleTask: { task in Task { await viewModel.toggleTask(task) } })
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: Grille

    private func grilleMode(_ payload: BoardPayload) -> some View {
        ScrollView {
            LazyVGrid(columns: grid, spacing: 12) {
                ForEach(payload.sortedLists()) { list in
                    ForEach(visibleCards(in: list, payload: payload)) { card in
                        Button { selectedCardId = SelectedCard(id: card.id) } label: {
                            CardRowView(
                                card: card,
                                taskLists: payload.taskLists(for: card),
                                tasks: payload.taskLists(for: card).flatMap { payload.tasks(for: $0) },
                                labels: payload.labels(for: card),
                                members: payload.members(for: card))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - FAB

    private var fab: some View {
        Button {
            showAddCard = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: Color.accentColor.opacity(0.4), radius: 10, y: 4)
        }
        .accessibilityLabel("Add card")
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
}

// MARK: - Kanban paging

/// Column paging that takes a deliberate swipe: anything shorter than `threshold` of
/// the viewport springs back to the column the gesture started on, so a stray nudge
/// never changes column. The proposed target already folds in the flick velocity, so
/// a quick short flick still counts as intentional — and `.viewAligned` does the
/// actual snapping, one column at a time.
private struct DeliberateColumnPaging: ScrollTargetBehavior {
    /// Share of the viewport a swipe must aim past before the column changes.
    private let threshold: CGFloat = 0.35

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let start = context.originalTarget.rect.minX
        if abs(target.rect.minX - start) < threshold * context.containerSize.width {
            target.rect.origin.x = start
            return
        }
        ViewAlignedScrollTargetBehavior(limitBehavior: .always)
            .updateTarget(&target, context: context)
    }
}

// MARK: - List-mode card row (card + its tasks)

private struct ListModeCardRow: View {
    let card: Card
    let tasks: [PlankaTask]
    var labels: [BoardlyKit.Label] = []
    let onTap: () -> Void
    let onToggleTask: (PlankaTask) -> Void

    private var completed: Int { tasks.filter(\.isCompleted).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 6) {
                    // Labels lead the row, above the title and counter, as in kanban.
                    CardLabelCluster(labels: labels, maxVisible: 4)
                    HStack(spacing: 10) {
                        Text(card.name)
                            .font(.sans(15, .semibold))
                            .foregroundStyle(Color.boardlyInk)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if let due = card.dueDate {
                            Text(due.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.mono(11, .medium))
                                .foregroundStyle(due < Date() ? Color.boardlyDestructive : Color.boardlyTextSecondary)
                        }
                        if !tasks.isEmpty {
                            Text("\(completed)/\(tasks.count)")
                                .font(.mono(11, .medium))
                                .foregroundStyle(Color.boardlyTextSecondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks) { task in
                        Button { onToggleTask(task) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.isCompleted ? Color.labelGreen : Color.boardlyTextTertiary)
                                    .font(.system(size: 15))
                                Text(task.name)
                                    .font(.boardlyCallout)
                                    .strikethrough(task.isCompleted)
                                    .foregroundStyle(task.isCompleted ? Color.boardlyTextSecondary : Color.boardlyInk)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .boardlyCard()
    }
}

private struct SelectedCard: Identifiable, Hashable {
    let id: String
}

/// A CSV export written to a temp file, ready to share.
private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL

    init(csv: String, name: String) {
        let safe = name.isEmpty ? "board" : name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).csv")
        try? Data(csv.utf8).write(to: url)
        self.url = url
    }
}

/// Thin wrapper around `UIActivityViewController` for the system share sheet.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
