import AppKit
import SwiftUI

/// The listening capsule's window.
///
/// It must never become key and never take focus: dictation inserts text into the field
/// another app has focused, and a panel that took key status or activated Murmur would pull
/// focus away and leave that insertion with no target. Several independent pieces hold that
/// line, and all of them must stay:
///  - the style mask includes `.nonactivatingPanel`, set at creation (changing it later is
///    unreliable);
///  - `canBecomeKey` and `canBecomeMain` are false, so a stray make-key call is refused;
///  - it is ordered in with `orderFrontRegardless()` only; nothing here calls `makeKey`,
///    `makeMain` or `NSApp.activate`;
///  - mouse events pass through to whatever is underneath;
///  - the hosted view has nothing focusable in it.
@MainActor
final class HUDPanel: NSPanel {
    /// Bumped by every present and dismiss, so a fade-out that finishes after the panel was
    /// brought back does not hide it.
    private var generation = 0
    /// What the panel is heading toward, as opposed to what `alphaValue` reads mid-fade.
    private var isShown = false

    init(controller: DictationController) {
        let inset = 2 * DS.HUD.margin
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: DS.HUD.width + inset, height: DS.HUD.height + inset),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        // The app is not active while the user dictates into another app; the default
        // would hide the panel exactly then.
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        let host = NSHostingView(rootView: HUDView(controller: controller))
        host.wantsLayer = true
        host.layer?.isOpaque = false
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centred above the Dock. `NSScreen.main` follows the key window, which this app never
    /// has, so it can be nil.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("HUD: no screen to place the panel on")
            return
        }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + DS.HUD.dockOffset
        ))
    }

    /// Called on every move between active states, not only the first; re-fading an
    /// already visible capsule would make it flicker mid-utterance.
    func present() {
        if isVisible, isShown { return }
        isShown = true
        generation += 1
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        fade(to: 1, completion: nil)
    }

    func dismiss() {
        isShown = false
        generation += 1
        let token = generation
        fade(to: 0) { [weak self] in
            // Not main-actor isolated, so hop rather than assume.
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.orderOut(nil)
            }
        }
    }

    private func fade(to alpha: CGFloat, completion: (@Sendable () -> Void)?) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.HUD.fadeDuration
            animator().alphaValue = alpha
        }, completionHandler: completion)
    }
}
