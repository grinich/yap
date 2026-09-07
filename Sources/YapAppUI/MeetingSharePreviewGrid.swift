import AppKit
import SwiftUI
import YapMeetings

/// AppKit supplies directional keyboard selection, focus, and scrolling. An
/// item selection only updates the sheet's choice; it never starts sharing.
struct MeetingSharePreviewGrid: NSViewRepresentable {
    let sources: [ShareTarget]
    let previews: [String: MeetingSharePreview]
    let previewsLoading: Bool
    let isEnabled: Bool
    @Binding var selectedID: String?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let collection = SharePreviewCollectionView(frame: NSRect(x: 0, y: 0, width: 580, height: 316))
        collection.autoresizingMask = [.width]
        collection.collectionViewLayout = SharePreviewLayout()
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.register(SharePreviewItem.self, forItemWithIdentifier: SharePreviewItem.reuseIdentifier)
        collection.setAccessibilityLabel("Choose a window or display to share")

        let scroll = SharePreviewScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        context.coordinator.collection = collection
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let sourcesChanged = coordinator.parent.sources != sources
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        collection.isSelectable = isEnabled
        if sourcesChanged || !coordinator.hasLoadedData {
            collection.reloadData()
            coordinator.hasLoadedData = true
        } else {
            // Refresh thumbnails without resetting selection, keyboard focus,
            // or scroll position every time an image finishes loading.
            for case let item as SharePreviewItem in collection.visibleItems() {
                guard let index = collection.indexPath(for: item), sources.indices.contains(index.item) else { continue }
                coordinator.configure(item, at: index)
            }
        }
        let selection: Set<IndexPath> = selectedID.flatMap { id in
            sources.firstIndex { $0.pickerID == id }.map { Set([IndexPath(item: $0, section: 0)]) }
        } ?? []
        if collection.selectionIndexPaths != selection { collection.selectionIndexPaths = selection }
        collection.alphaValue = isEnabled ? 1 : 0.55
    }

    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: MeetingSharePreviewGrid
        weak var collection: NSCollectionView?
        var isUpdating = false
        var hasLoadedData = false

        init(parent: MeetingSharePreviewGrid) { self.parent = parent }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.sources.count
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: SharePreviewItem.reuseIdentifier, for: indexPath)
            if let item = item as? SharePreviewItem { configure(item, at: indexPath) }
            return item
        }

        fileprivate func configure(_ item: SharePreviewItem, at indexPath: IndexPath) {
            let source = parent.sources[indexPath.item]
            item.source = source
            item.preview = parent.previews[source.pickerID]
            item.isLoadingPreview = parent.previewsLoading
            item.refresh()
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !isUpdating, parent.isEnabled, let index = indexPaths.first,
                  parent.sources.indices.contains(index.item) else { return }
            parent.selectedID = parent.sources[index.item].pickerID
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            guard !isUpdating, parent.isEnabled, collectionView.selectionIndexPaths.isEmpty else { return }
            parent.selectedID = nil
        }
    }
}

private final class SharePreviewScrollView: NSScrollView {
    private var laidOutViewportWidth: CGFloat = -1

    override func tile() {
        super.tile()
        let width = contentSize.width
        guard width != laidOutViewportWidth else { return }
        laidOutViewportWidth = width
        // The scroller can change the clip width after the collection's
        // prepare pass. Reflow against the final viewport, including native
        // overlay/legacy changes, instead of retaining stale column geometry.
        (documentView as? NSCollectionView)?.collectionViewLayout?.invalidateLayout()
    }
}

private final class SharePreviewCollectionView: NSCollectionView {
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if isSelectable, selectionIndexPaths.isEmpty, modifiers.isEmpty,
           [123, 124, 125, 126].contains(event.keyCode), numberOfSections > 0,
           numberOfItems(inSection: 0) > 0 {
            // AppKit navigates an existing selection, but does not establish
            // one on the first arrow. This is a choice, never a Share action.
            let selection: Set<IndexPath> = [IndexPath(item: 0, section: 0)]
            selectItems(at: selection, scrollPosition: .top)
            delegate?.collectionView?(self, didSelectItemsAt: selection)
            return
        }
        super.keyDown(with: event)
    }
}

private final class SharePreviewLayout: NSCollectionViewFlowLayout {
    override init() {
        super.init()
        minimumInteritemSpacing = 12
        minimumLineSpacing = 12
        sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    }
    required init?(coder: NSCoder) { nil }

    override func prepare() {
        // SwiftUI can initially measure the document at an ideal width larger
        // than its final viewport. Flow layout wraps within the scroll view.
        let width = collectionView?.enclosingScrollView?.contentSize.width
            ?? collectionView?.bounds.width ?? 572
        itemSize = NSSize(width: max(150, floor((width - 36) / 3)), height: 146)
        super.prepare()
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

private final class SharePreviewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("YapSharePreview")
    var source: ShareTarget?
    var preview: MeetingSharePreview?
    var isLoadingPreview = false
    private var hosting: NSHostingView<SharePreviewCard>?

    override var isSelected: Bool { didSet { refresh() } }

    override func loadView() {
        view = NSView()
    }

    func refresh() {
        guard let source else { return }
        let card = SharePreviewCard(source: source, preview: preview, loading: isLoadingPreview, selected: isSelected)
        if let hosting { hosting.rootView = card }
        else {
            let hosting = NSHostingView(rootView: card)
            hosting.frame = view.bounds
            hosting.autoresizingMask = [.width, .height]
            view.addSubview(hosting)
            self.hosting = hosting
        }
        view.toolTip = source.previewSourceTitle
        view.setAccessibilityLabel(source.previewSourceTitle)
    }
}

private struct SharePreviewCard: View {
    let source: ShareTarget
    let preview: MeetingSharePreview?
    let loading: Bool
    let selected: Bool

    private var title: String {
        guard let app = preview?.applicationName, source.title.hasPrefix(app + " — ") else {
            return source.previewSourceTitle
        }
        return String(source.title.dropFirst(app.count + 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
                if let image = preview?.image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(4)
                } else if source.kind == .demo {
                    VStack(spacing: 5) {
                        Image(systemName: "rectangle.dashed").font(.title2)
                        Text("Sample only").font(.caption)
                    }.foregroundStyle(.secondary)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: source.kind == .display ? "display" : "macwindow").font(.title2)
                        Text("Preview unavailable").font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
            .frame(height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1))
            Text(title).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if let icon = preview?.applicationIcon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(preview?.applicationName ?? (source.kind == .display ? "Entire display" : source.kind == .demo ? "Interface preview" : "Window"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.previewSourceTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension ShareTarget {
    var previewSourceTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        switch kind {
        case .window: return "Untitled window"
        case .display: return "Display"
        case .demo: return "Sample content"
        }
    }
}
