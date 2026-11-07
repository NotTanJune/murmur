import Foundation

/// The legacy HTML results page. The in-app comparison window replaced it, but the app
/// still writes it beside the history file and `murmur://` links still point at it.
///
/// Pure and nonisolated: `RunLog` calls it from its serial history queue.
enum DashboardHTML {
    static func render(
        runs: [DictationRun],
        compareMode: Bool = false,
        key: String = "Right \u{2325}"
    ) -> String {
        var body = ""
        body += "<h1>Murmur engine comparison</h1>\n"
        body += statusBar(count: runs.count)
        if runs.isEmpty {
            body += emptyState(compareMode: compareMode, key: key)
        } else {
            body += groupsSection(runs)
            body += totalsSection(runs)
            body += tableSection(runs)
        }
        body += footer

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="refresh" content="3">
        <title>Murmur: engine comparison</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>
        """
    }

    // MARK: - Sections

    private static func statusBar(count: Int) -> String {
        let noun = count == 1 ? "dictation" : "dictations"
        var html = "<div class=\"status\"><div class=\"live\"><span class=\"dot\"></span>"
        html += "<span>Live, reloads every 3 seconds. \(count) \(noun) recorded.</span></div>\n"
        if count > 0 {
            html += "<a class=\"button\" href=\"murmur://clear\">Clear results</a>\n"
        }
        html += "</div>\n"
        return html
    }

    private static func emptyState(compareMode: Bool, key: String) -> String {
        let second = compareMode
            ? "Both engines will run on that one recording and appear here side by side."
            : "Compare mode is off. Turn it on from the menu bar to run both engines on one recording."
        return """
        <section class="empty">
        <p class="lead">Hold <kbd>\(escape(key))</kbd>, say a sentence, and let go.</p>
        <p>\(second)</p>
        <p class="hint">Nothing to click: this page fills in on its own.</p>
        </section>

        """
    }

    private static func groupsSection(_ runs: [DictationRun]) -> String {
        var order: [String] = []
        var members: [String: [DictationRun]] = [:]
        for run in runs {
            guard let group = run.group else { continue }
            if members[group] == nil { order.append(group) }
            members[group, default: []].append(run)
        }
        guard !order.isEmpty else { return "" }

        let newestFirst = order.sorted {
            (members[$0]?.first?.date ?? .distantPast) > (members[$1]?.first?.date ?? .distantPast)
        }
        var html = "<h2>Side-by-side comparisons</h2>\n"
        for group in newestFirst {
            if let groupRuns = members[group] { html += groupPanel(groupRuns) }
        }
        return html
    }

    private static func groupPanel(_ runs: [DictationRun]) -> String {
        guard let first = runs.first else { return "" }
        let (verdictText, agrees) = verdict(for: runs)
        let fastest = runs.count >= 2 ? runs.min { $0.processSeconds < $1.processSeconds }?.engine : nil

        var html = "<section class=\"panel\">\n<header>\n"
        html += "<div class=\"when\"><span class=\"num\">\(clock(first.date))</span>"
        html += "<span class=\"muted\">held \(fixed(first.audioSeconds, 1)) s</span></div>\n"
        html += "<span class=\"badge \(agrees ? "agree" : "differ")\">\(verdictText)</span>\n"
        html += "</header>\n<div class=\"columns\">\n"
        for run in runs {
            let isFastest = run.engine == fastest
            html += "<article>\n<div class=\"line\">"
            html += "<span class=\"pill\(isFastest ? " best" : "")\">\(escape(run.engine))"
            html += isFastest ? " &middot; fastest" : ""
            html += "</span>"
            html += "<span class=\"big num\">\(fixed(run.processSeconds, 2)) s</span></div>\n"
            html += "<div class=\"meta num\">\(fixed(run.realtimeFactor, 0))&times; real time &middot; "
            html += "\(run.characters) characters</div>\n"
            html += "<p class=\"text\">\(escape(run.text))</p>\n</article>\n"
        }
        html += "</div>\n</section>\n"
        return html
    }

    private static func totalsSection(_ runs: [DictationRun]) -> String {
        let engines = Set(runs.map(\.engine)).sorted()
        var html = "<h2>Per-engine totals</h2>\n<div class=\"cards\">\n"
        for engine in engines {
            let mine = runs.filter { $0.engine == engine }
            let noun = mine.count == 1 ? "run" : "runs"
            html += "<section class=\"card\">\n<div class=\"pill\">\(escape(engine))</div>\n"
            html += "<div class=\"meta\">\(mine.count) \(noun), medians</div>\n<div class=\"stats\">\n"
            html += stat("Process time", "\(fixed(median(mine.map(\.processSeconds)), 2)) s")
            html += stat("RTF", "\(fixed(median(mine.map(\.realtimeFactor)), 0))&times;")
            html += stat("Characters", "\(mine.reduce(0) { $0 + $1.characters })")
            html += "</div>\n</section>\n"
        }
        html += "</div>\n"
        return html
    }

    private static func tableSection(_ runs: [DictationRun]) -> String {
        let loose = runs.filter { $0.group == nil }.reversed()
        guard !loose.isEmpty else { return "" }
        var html = "<h2>Dictations</h2>\n<div class=\"scroll\"><table>\n<thead><tr>"
        for heading in ["Time", "Engine", "Held", "Process", "RTF", "Transcript"] {
            html += "<th>\(heading)</th>"
        }
        html += "</tr></thead>\n<tbody>\n"
        for run in loose {
            html += "<tr><td class=\"num\">\(clock(run.date))</td>"
            html += "<td><span class=\"pill\">\(escape(run.engine))</span></td>"
            html += "<td class=\"num\">\(fixed(run.audioSeconds, 1)) s</td>"
            html += "<td class=\"num\">\(fixed(run.processSeconds, 2)) s</td>"
            html += "<td class=\"num\">\(fixed(run.realtimeFactor, 0))&times;</td>"
            html += "<td class=\"transcript\">\(escape(run.text))</td></tr>\n"
        }
        html += "</tbody>\n</table></div>\n"
        return html
    }

    private static let footer = """
    <footer>
    <p><strong>Process time</strong> is the wait from key release to text ready, the latency you feel.
    <strong>RTF</strong> (real-time factor) is hold duration divided by process time.</p>
    <p>Apple's engine streams text while you talk, and Parakeet and Bark stream by default too,
    so the latency you feel can be lower than the number suggests. Medians are shown so a single
    cold start does not define an engine.</p>
    </footer>

    """

    // MARK: - Pieces

    private static func stat(_ label: String, _ value: String) -> String {
        "<div class=\"stat\"><div class=\"label\">\(label)</div><div class=\"value num\">\(value)</div></div>\n"
    }

    /// Exact match, then a match after folding case and punctuation, otherwise different.
    /// Apple punctuates and Parakeet does not, so the middle case is not a real difference.
    private static func verdict(for runs: [DictationRun]) -> (text: String, agrees: Bool) {
        let texts = runs.map(\.text)
        if Set(texts).count <= 1 { return ("Identical", true) }
        if Set(texts.map(normalise)).count <= 1 { return ("Same words, different punctuation or case", true) }
        return ("Different words", false)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .joined(separator: " ")
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Fixed decimals with a dot, whatever the user's locale.
    private static func fixed(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Style

    private static let css = #"""
    :root {
      color-scheme: light dark;
      --bg: #f6f4ee; --card: #ffffff; --ink: #1c1b19; --muted: #6f6c64;
      --line: #e3dfd3; --accent: #5b4bd6; --accent-bg: #ece9fb;
      --good: #1f7a4d; --good-bg: #e2f3ea; --bad: #a3481f; --bad-bg: #fbeadf;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #161513; --card: #1f1e1b; --ink: #ecebe6; --muted: #9a978d;
        --line: #33312c; --accent: #a99dff; --accent-bg: #2a2650;
        --good: #6fd09c; --good-bg: #183225; --bad: #f0a27a; --bad-bg: #3a2418;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--bg); color: var(--ink);
      font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
    }
    main { max-width: 1000px; margin: 0 auto; padding: 32px 20px 64px; }
    h1 { font-size: 26px; margin: 0 0 16px; }
    h2 { font-size: 13px; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 32px 0 12px; }
    .num { font-variant-numeric: tabular-nums; }
    .muted, .meta, footer { color: var(--muted); }
    .status { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
    .live { display: flex; align-items: center; gap: 8px; color: var(--muted); }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #2fb36b; animation: pulse 1.6s ease-in-out infinite; }
    @keyframes pulse { 50% { opacity: .35; } }
    .button { padding: 6px 12px; border: 1px solid var(--line); border-radius: 8px; color: var(--ink); background: var(--card); text-decoration: none; }
    .empty, .panel, .card, .scroll { background: var(--card); border: 1px solid var(--line); border-radius: 12px; }
    .empty { padding: 32px; text-align: center; }
    .empty .lead { font-size: 18px; }
    .hint { color: var(--muted); font-size: 13px; }
    kbd { padding: 2px 8px; border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 6px; font: inherit; background: var(--bg); }
    .panel { margin-bottom: 16px; overflow: hidden; }
    .panel header { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 12px 16px; border-bottom: 1px solid var(--line); }
    .when { display: flex; gap: 12px; align-items: baseline; }
    .badge { padding: 2px 10px; border-radius: 999px; font-size: 13px; }
    .badge.agree { color: var(--good); background: var(--good-bg); }
    .badge.differ { color: var(--bad); background: var(--bad-bg); }
    .columns { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
    .columns article { padding: 16px; border-right: 1px solid var(--line); }
    .line { display: flex; align-items: baseline; justify-content: space-between; gap: 8px; }
    .pill { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 13px; color: var(--accent); background: var(--accent-bg); }
    .pill.best { color: var(--good); background: var(--good-bg); }
    .big { font-size: 22px; }
    .meta { font-size: 13px; margin: 4px 0 8px; }
    .text { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }
    .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px; }
    .card { padding: 16px; }
    .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 12px; }
    .stat { padding: 8px; border: 1px solid var(--line); border-radius: 8px; }
    .stat .label { font-size: 12px; color: var(--muted); }
    .stat .value { font-size: 18px; }
    .scroll { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; }
    th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { font-size: 12px; color: var(--muted); font-weight: 600; }
    tr:last-child td { border-bottom: 0; }
    .transcript { color: var(--muted); max-width: 420px; overflow-wrap: anywhere; }
    footer { margin-top: 32px; font-size: 13px; }
    """#
}
