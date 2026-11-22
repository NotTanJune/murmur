import MurmurDesign
import SwiftUI
import UIKit

/// One row of the history panel.
struct HistoryEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let text: String
}

/// The history panel's list: a `UITableView`, not a SwiftUI `ScrollView` of `Button`s.
///
/// The SwiftUI version read as inaccurate on a device (2026-11-22): every row was a button that
/// took the touch at once, so a short flick could end as a tap that typed the row and closed the
/// panel, and the scroll did not follow the finger the way a system list does. A table view
/// gives the system's arbitration: it waits before highlighting, cancels the row as soon as the
/// finger moves, fires only on a clean lift, and scrolls touching no SwiftUI state. The emoji
/// grid moved to UIKit for the same family of reasons (AGENTS.md, "The grid is UIKit").
struct HistoryList: UIViewRepresentable {
    let entries: [HistoryEntry]
    /// A row was tapped: its text, to type again.
    let onSelect: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITableView {
        let table = UITableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.isOpaque = false
        table.showsVerticalScrollIndicator = false
        table.separatorInset = UIEdgeInsets(top: 0, left: DS.Keyboard.historyRowInsetX, bottom: 0, right: 0)
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 56
        table.alwaysBounceVertical = true
        // iOS 26's soft scroll edge blurred the first row under the header; off, as before.
        table.topEdgeEffect.isHidden = true
        table.bottomEdgeEffect.isHidden = true
        table.register(HistoryCell.self, forCellReuseIdentifier: HistoryCell.reuseID)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.entries = entries
        return table
    }

    func updateUIView(_ table: UITableView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Reload only when the rows changed, so a SwiftUI pass never resets a scroll.
        guard coordinator.entries != entries else { return }
        coordinator.entries = entries
        table.reloadData()
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        var parent: HistoryList
        var entries: [HistoryEntry] = []

        init(_ parent: HistoryList) {
            self.parent = parent
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            entries.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: HistoryCell.reuseID, for: indexPath)
            if let cell = cell as? HistoryCell { cell.configure(entries[indexPath.row]) }
            return cell
        }

        func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
            tableView.deselectRow(at: indexPath, animated: false)
            UIDevice.current.playInputClick()
            parent.onSelect(entries[indexPath.row].text)
        }
    }
}

private final class HistoryCell: UITableViewCell {
    static let reuseID = "HistoryCell"

    private let body = UILabel()
    private let time = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let pressed = UIView()
        pressed.backgroundColor = .systemFill
        selectedBackgroundView = pressed

        body.font = DS.Keyboard.historyRowUIFont
        body.textColor = .label
        body.numberOfLines = DS.Keyboard.historyRowLines
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        time.font = DS.Keyboard.historyTimeUIFont
        time.textColor = .tertiaryLabel
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [body, time])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = DS.Keyboard.historyRowInsetX
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        let insetX = DS.Keyboard.historyRowInsetX
        let insetY = DS.Keyboard.historyRowInsetY
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insetX),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insetX),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insetY),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insetY),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "Types it again"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ entry: HistoryEntry) {
        body.text = entry.text
        time.text = entry.date.formatted(.relative(presentation: .named, unitsStyle: .narrow))
        accessibilityLabel = "\(entry.text), \(time.text ?? "")"
    }
}
