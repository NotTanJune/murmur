import MurmurDesign
import MurmurKit
import SwiftUI
import UIKit

/// The emoji picker's grid: a horizontal `UICollectionView`, `rows` emoji tall, with one section
/// per category and each section starting on a fresh column. UIKit and not a SwiftUI
/// `LazyHGrid` because the grid is about 1,900 cells: SwiftUI builds and discards a view per
/// cell with a tap and a long-press gesture on each, re-walks the ids on every body pass, and
/// `ScrollPosition.scrollTo` neither interrupts momentum nor reliably reaches an unrealised
/// item. Here a cell is a recycled `UILabel`, scrolling touches no SwiftUI state, and a
/// category tap stops whatever is moving and goes straight to its section.
///
/// SwiftUI hears about the grid in three ways only: the section in view changed, an emoji was
/// chosen, or a long press (or the VoiceOver action) asked for skin tones. A grid made without
/// `onTones` (the search results) has no long press and no tone action.
struct EmojiGrid: UIViewRepresentable {
    let categories: [EmojiCatalog.Category]
    let rows: Int
    let columns: Int
    let controller: EmojiGridController
    /// The section at the leading edge changed. Called on a change only, never per frame.
    let onSection: (Int) -> Void
    /// An emoji was tapped; the form to type.
    let onSelect: (String) -> Void
    /// Skin tones were asked for: the emoji as shown, whether it is a Frequently Used form, and
    /// its cell in the grid's own coordinates. Nil leaves tones out of the grid altogether: no
    /// long-press recognizer and no VoiceOver action (the search results, which show the
    /// remembered tone but do not offer a choice).
    let onTones: ((_ emoji: String, _ isRecent: Bool, _ anchor: CGRect) -> Void)?
    /// While the finger that opened the tone row stays down: where it is, in the panel's
    /// coordinates (the grid starts below the search field), on each move.
    var onToneDrag: ((_ point: CGPoint) -> Void)?
    /// The same finger lifted (or the touch was cancelled), at that point in the panel's coordinates.
    var onToneRelease: ((_ point: CGPoint) -> Void)?
    /// Changes when `categories` holds different emoji (search results), which reloads the grid
    /// and returns it to the start. The panel's own grid never changes it: it is read once.
    var reloadToken = 0
    /// The compact (landscape) layout, whose rows are shorter, so its glyphs are smaller.
    var compact = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        coordinator.layout.configure(counts: categories.map(\.emoji.count), rows: rows, columns: columns)
        let view = EmojiCollectionView(frame: .zero, collectionViewLayout: coordinator.layout)
        view.onResize = { [weak coordinator, weak view] in
            if let coordinator, let view { coordinator.pinToPublishedSection(in: view) }
        }
        view.backgroundColor = .clear
        view.isOpaque = false
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.alwaysBounceVertical = false
        view.contentInsetAdjustmentBehavior = .never
        // iOS 26 fades a scroll view's edges; the grid ends in the keyboard's own edge.
        view.leftEdgeEffect.isHidden = true
        view.rightEdgeEffect.isHidden = true
        view.topEdgeEffect.isHidden = true
        view.bottomEdgeEffect.isHidden = true
        view.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseIdentifier)
        view.dataSource = coordinator
        view.delegate = coordinator
        if onTones != nil {
            let press = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.pressed(_:)))
            press.minimumPressDuration = DS.Keyboard.emojiLongPress
            view.addGestureRecognizer(press)
        }
        coordinator.collectionView = view
        controller.coordinator = coordinator
        return view
    }

    func updateUIView(_ view: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.applyContent(token: reloadToken, in: view)
        coordinator.applyShape(rows: rows, columns: columns, in: view)
    }

    /// Fills the space it is given. A collection view has no intrinsic size.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UICollectionView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var parent: EmojiGrid
        let layout = EmojiGridLayout()
        weak var collectionView: UICollectionView?
        private let tones = EmojiTonePreference(defaults: MurmurEnvironment.defaults)
        /// Preferred forms looked up so far, so a cell being configured does not read
        /// `UserDefaults`; cleared when a tone is chosen.
        private var toneCache: [String: String] = [:]
        /// The cell a tone row was opened from, so VoiceOver can go back to it.
        private var tonesPath: IndexPath?
        /// The section last reported to SwiftUI.
        private var published = 0
        /// Set by a category tap and held until the finger takes the grid, so the offset passing
        /// through the sections in between neither flicks the title nor moves the highlight away
        /// from the tap. The target can be short of the section's own start (the last sections
        /// cannot scroll that far), and this keeps the tapped one lit then too.
        private var lockedSection: Int?
        /// Where the scroll that set `lockedSection` is going, to tell its end from an older one's.
        private var lockedTargetX: CGFloat = 0

        /// The `reloadToken` the cells were last loaded for.
        private var loadedToken: Int

        init(_ parent: EmojiGrid) {
            self.parent = parent
            loadedToken = parent.reloadToken
        }

        /// The panel's categories are fixed for its life (Frequently Used is read once when it
        /// opens), so the data source reads them live and is reloaded only when `reloadToken`
        /// changes (the search's results).
        private var categories: [EmojiCatalog.Category] { parent.categories }

        // MARK: Content

        /// New categories under the same grid (the search's results): reload, forget the tones read
        /// so far, and start from the first column.
        func applyContent(token: Int, in view: UICollectionView) {
            guard token != loadedToken else { return }
            loadedToken = token
            layout.configure(counts: categories.map(\.emoji.count), rows: layout.rows, columns: layout.columns)
            toneCache.removeAll()
            lockedSection = nil
            published = 0
            view.reloadData()
            view.layoutIfNeeded()
            view.setContentOffset(.zero, animated: false)
        }

        // MARK: Shape

        func applyShape(rows: Int, columns: Int, in view: UICollectionView) {
            guard layout.rows != rows || layout.columns != columns else { return }
            let section = published
            // Re-laying out can move the offset; that is not the finger, so it reports nothing.
            lockedSection = section
            layout.configure(counts: categories.map(\.emoji.count), rows: rows, columns: columns)
            view.layoutIfNeeded()
            // The columns changed, so the old offset points somewhere else; return to the section.
            scroll(toSection: section, animated: false)
        }

        // MARK: Scrolling

        /// Every call is honoured at once: a scroll or deceleration in flight is stopped where it
        /// is, and the new one starts from there.
        func scroll(toSection index: Int, animated: Bool = true) {
            guard let view = collectionView, categories.indices.contains(index) else { return }
            lockedSection = index
            lockedTargetX = layout.offsetX(ofSection: index)
            report(index)
            view.setContentOffset(view.contentOffset, animated: false)
            view.setContentOffset(CGPoint(x: lockedTargetX, y: 0), animated: animated)
        }

        /// The view's size changed (rotation, the keyboard's height), and `applyShape` ran with the
        /// old bounds. Put the section in view back at the leading edge for the new cell width.
        func pinToPublishedSection(in view: UICollectionView) {
            lockedSection = published
            lockedTargetX = layout.offsetX(ofSection: published)
            view.setContentOffset(CGPoint(x: lockedTargetX, y: 0), animated: false)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // The grid scrolls sideways only. Its content is exactly as tall as the view with no
            // insets and no vertical bounce, so this never fires; it keeps a row from ever being
            // cut at the top by a vertical offset, whatever UIKit does on a resize.
            if scrollView.contentOffset.y != 0 { scrollView.contentOffset.y = 0 }
            guard lockedSection == nil else { return }
            report(layout.section(atOffsetX: scrollView.contentOffset.x))
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            lockedSection = nil
        }

        /// A category tap's scroll arrived: the offset follows the finger again. When it stopped
        /// short of the target (an older animation ending, or a touch cutting it off) the lock
        /// stays until the next drag. The tapped section stays lit even where the target was
        /// clamped, so the section is not recomputed here.
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard lockedSection != nil, abs(scrollView.contentOffset.x - lockedTargetX) < 1 else { return }
            lockedSection = nil
        }

        private func report(_ section: Int) {
            guard section != published else { return }
            published = section
            parent.onSection(section)
        }

        // MARK: Cells

        func numberOfSections(in collectionView: UICollectionView) -> Int { categories.count }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            categories[section].emoji.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseIdentifier, for: indexPath)
            if let cell = cell as? EmojiCell { configure(cell, at: indexPath) }
            return cell
        }

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            // Nothing stays selected, so the same emoji can be tapped again at once.
            collectionView.deselectItem(at: indexPath, animated: false)
            parent.onSelect(shown(at: indexPath))
        }

        /// The form of an emoji the grid shows: the preferred tone of one that has any. Frequently
        /// Used shows what was typed, which already carries its tone.
        private func shown(at path: IndexPath) -> String {
            let category = categories[path.section]
            let emoji = category.emoji[path.item]
            if category.id == "recents" || EmojiCatalog.tones(for: emoji).isEmpty { return emoji }
            if let cached = toneCache[emoji] { return cached }
            let preferred = tones.preferred(for: emoji)
            toneCache[emoji] = preferred
            return preferred
        }

        private func hasTones(at path: IndexPath) -> Bool {
            let category = categories[path.section]
            let emoji = category.emoji[path.item]
            let base = category.id == "recents" ? (EmojiCatalog.base(ofToned: emoji) ?? emoji) : emoji
            return !EmojiCatalog.tones(for: base).isEmpty
        }

        private func configure(_ cell: EmojiCell, at path: IndexPath) {
            let emoji = shown(at: path)
            cell.setGlyphSize(parent.compact ? DS.Keyboard.emojiGlyphSizeCompact : DS.Keyboard.emojiGlyphSize)
            cell.show(emoji)
            cell.onActivate = { [weak self] in self?.parent.onSelect(emoji) }
            if parent.onTones != nil, hasTones(at: path) {
                cell.accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: "Skin tones") { [weak self] _ in
                        self?.requestTones(at: path)
                        return true
                    },
                ]
            } else {
                cell.accessibilityCustomActions = nil
            }
        }

        /// Redraws the cells in view after a tone was chosen; the others read the preference when
        /// they are next dequeued.
        func refreshVisible() {
            toneCache.removeAll()
            guard let view = collectionView else { return }
            for path in view.indexPathsForVisibleItems {
                if let cell = view.cellForItem(at: path) as? EmojiCell { configure(cell, at: path) }
            }
        }

        // MARK: Skin tones

        /// The tone row closed: with VoiceOver on, focus goes back to the cell it came from
        /// rather than staying on the row that is gone.
        func returnFocusToPressedCell() {
            guard UIAccessibility.isVoiceOverRunning, let path = tonesPath,
                  let cell = collectionView?.cellForItem(at: path) else { return }
            UIAccessibility.post(notification: .layoutChanged, argument: cell)
        }

        /// True from a long press that opened the tone row until that finger lifts.
        private var pressOpenedTones = false

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = collectionView else { return }
            // The grid's coordinates start below the search field in the panel's.
            let location = recognizer.location(in: view)
            let point = CGPoint(x: location.x, y: location.y + DS.Keyboard.emojiGridTop)
            switch recognizer.state {
            case .began:
                guard let path = view.indexPathForItem(at: location) else { return }
                tonesPath = nil
                requestTones(at: path)
                if tonesPath == path {
                    pressOpenedTones = true
                    // The finger now slides over the row, so the grid must not scroll under it.
                    view.isScrollEnabled = false
                }
            case .changed:
                if pressOpenedTones { parent.onToneDrag?(point) }
            case .ended, .cancelled, .failed:
                guard pressOpenedTones else { return }
                pressOpenedTones = false
                view.isScrollEnabled = true
                parent.onToneRelease?(point)
            default:
                break
            }
        }

        private func requestTones(at path: IndexPath) {
            guard let onTones = parent.onTones, let view = collectionView, hasTones(at: path),
                  let frame = layout.layoutAttributesForItem(at: path)?.frame else { return }
            let anchor = frame.offsetBy(dx: -view.contentOffset.x, dy: -view.contentOffset.y)
            tonesPath = path
            onTones(shown(at: path), categories[path.section].id == "recents", anchor)
        }
    }
}

/// How the panel reaches into the grid: a category tap scrolls it, a chosen tone redraws it.
/// A plain box with nothing observable, so holding one in `@State` redraws nothing.
@MainActor
final class EmojiGridController {
    fileprivate weak var coordinator: EmojiGrid.Coordinator?

    func scroll(toSection index: Int) { coordinator?.scroll(toSection: index) }
    func refreshVisible() { coordinator?.refreshVisible() }
    func returnFocusToPressedCell() { coordinator?.returnFocusToPressedCell() }
}

/// A collection view that says when its size changes, after layout, so the grid can re-pin its
/// offset to the new cell width (`updateUIView` runs with the old bounds).
private final class EmojiCollectionView: UICollectionView {
    var onResize: (() -> Void)?
    private var laidOutSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        laidOutSize = bounds.size
        onResize?()
    }
}

// MARK: Cell

/// One emoji: a label and nothing else, reused as the grid scrolls.
private final class EmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "emoji"

    private let label = UILabel()
    var onActivate: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.frame = contentView.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.textAlignment = .center
        label.font = .systemFont(ofSize: DS.Keyboard.emojiGlyphSize)
        label.adjustsFontForContentSizeCategory = false
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setGlyphSize(_ size: CGFloat) {
        guard label.font.pointSize != size else { return }
        label.font = .systemFont(ofSize: size)
    }

    func show(_ emoji: String) {
        guard label.text != emoji else { return }
        label.text = emoji
        accessibilityLabel = emoji
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
    }

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }
}

// MARK: Layout

/// Column-major rows: item `n` of a section sits in column `n / rows` from the section's first
/// column, row `n % rows`, and a section's last column may be short. Each section starts on a
/// whole column, so the leading edge names its section. A cell is the view's width over
/// `columns` and its height over `rows`, so the grid always fills the space it is given.
final class EmojiGridLayout: UICollectionViewLayout {
    private(set) var rows = 1
    private(set) var columns = 1
    private var counts: [Int] = []
    private var startColumns: [Int] = []
    private var totalColumns = 0

    func configure(counts: [Int], rows: Int, columns: Int) {
        self.counts = counts
        self.rows = max(rows, 1)
        self.columns = max(columns, 1)
        var start = 0
        startColumns = counts.map { count in
            defer { start += (count + self.rows - 1) / self.rows }
            return start
        }
        totalColumns = start
        invalidateLayout()
    }

    private var viewSize: CGSize { collectionView?.bounds.size ?? .zero }
    private var cellWidth: CGFloat { viewSize.width / CGFloat(columns) }
    private var cellHeight: CGFloat { viewSize.height / CGFloat(rows) }

    /// The section whose columns hold the one at `offset` (rounded to the nearest column, so the
    /// title changes when a section is more than half in).
    func section(atOffsetX offset: CGFloat) -> Int {
        let width = cellWidth
        guard width > 0 else { return 0 }
        let column = Int((offset / width).rounded())
        return startColumns.lastIndex { $0 <= column } ?? 0
    }

    /// Where the grid scrolls to for a section: its first column at the leading edge, or as far
    /// as the content goes for the last sections.
    func offsetX(ofSection section: Int) -> CGFloat {
        guard startColumns.indices.contains(section) else { return 0 }
        let wanted = CGFloat(startColumns[section]) * cellWidth
        return min(wanted, max(collectionViewContentSize.width - viewSize.width, 0))
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: CGFloat(totalColumns) * cellWidth, height: viewSize.height)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.size != viewSize
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard startColumns.indices.contains(indexPath.section), indexPath.item < counts[indexPath.section] else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let column = startColumns[indexPath.section] + indexPath.item / rows
        let row = indexPath.item % rows
        attributes.frame = CGRect(
            x: CGFloat(column) * cellWidth, y: CGFloat(row) * cellHeight,
            width: cellWidth, height: cellHeight
        )
        return attributes
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let width = cellWidth
        guard width > 0, totalColumns > 0 else { return [] }
        let first = max(Int((rect.minX / width).rounded(.down)), 0)
        let last = min(Int((rect.maxX / width).rounded(.down)), totalColumns - 1)
        guard first <= last else { return [] }
        var result: [UICollectionViewLayoutAttributes] = []
        result.reserveCapacity((last - first + 1) * rows)
        var section = startColumns.lastIndex { $0 <= first } ?? 0
        for column in first...last {
            while section + 1 < startColumns.count, startColumns[section + 1] <= column { section += 1 }
            for row in 0..<rows {
                let item = (column - startColumns[section]) * rows + row
                guard item < counts[section],
                      let attributes = layoutAttributesForItem(at: IndexPath(item: item, section: section)) else { continue }
                result.append(attributes)
            }
        }
        return result
    }
}
