import ObjectiveC
import UIKit

/// Diagnostics only: watches every window of the keyboard's process for touches, one level
/// below the key plane, so a lost tap can be placed. While typing diagnostics are on it logs
///
/// - `whit`: each hit test a window runs for a touch, with the view it found. A lost tap with
///   no `whit` never reached this process's hit testing (it went to another process, or the
///   system dropped it). A `whit` that found nothing, or a view other than the key plane, names
///   the view in the plane's ancestry that refused it.
/// - `event`: each touch a window dispatches in its `began` phase, with the phases of the other
///   touches in the event. A `whit` on the plane with no `event` after it is a touch UIKit
///   dropped after hit testing.
///
/// The two `UIWindow` methods are swizzled once per process, and do nothing but one comparison
/// while diagnostics are off.
@MainActor
enum WindowProbe {
    private static var installed = false
    static weak var plane: UIView?
    fileprivate static var lastHit: (TimeInterval, Int, Int)?

    static func install() {
        guard !installed else { return }
        installed = true
        swizzle(#selector(UIWindow.hitTest(_:with:)), #selector(UIWindow.murmurProbe_hitTest(_:with:)))
        swizzle(#selector(UIWindow.sendEvent(_:)), #selector(UIWindow.murmurProbe_sendEvent(_:)))
    }

    /// Swaps two methods on `UIWindow` only. When `UIWindow` inherits the original (`hitTest`
    /// comes from `UIView`), exchanging implementations would change it for every view, so the
    /// probe is first added to `UIWindow` under the original's name and the inherited
    /// implementation is filed under the probe's.
    private static func swizzle(_ original: Selector, _ probe: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIWindow.self, original),
              let probeMethod = class_getInstanceMethod(UIWindow.self, probe)
        else { return }
        let added = class_addMethod(
            UIWindow.self, original, method_getImplementation(probeMethod), method_getTypeEncoding(probeMethod))
        if added {
            class_replaceMethod(
                UIWindow.self, probe, method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod))
        } else {
            method_exchangeImplementations(originalMethod, probeMethod)
        }
    }

    /// Why a point inside the plane did not hit-test to it: the first view from the plane up
    /// to the window that is hidden, clear, not interactive or does not contain the point.
    fileprivate static func refusal(for point: CGPoint, in window: UIWindow) -> String? {
        guard let plane, plane.window === window else { return nil }
        guard plane.bounds.contains(plane.convert(point, from: window)) else { return nil }
        var node: UIView? = plane
        while let view = node {
            let name = String(describing: type(of: view))
            if view.isHidden { return "\(name) hidden" }
            if view.alpha < 0.01 { return "\(name) alpha \(view.alpha)" }
            if !view.isUserInteractionEnabled { return "\(name) not interactive" }
            if !view.point(inside: view.convert(point, from: window), with: nil) { return "\(name) outside" }
            node = view.superview
        }
        return "no refusing ancestor"
    }
}

extension UIWindow {
    @objc dynamic func murmurProbe_hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // After the swizzle this name holds the original implementation.
        let view = murmurProbe_hitTest(point, with: event)
        guard TypingDiagnostics.isOn, let event, event.type == .touches else { return view }
        let key = (event.timestamp, Int(point.x), Int(point.y))
        if let last = WindowProbe.lastHit, last == key { return view }
        WindowProbe.lastHit = key
        var fields: [String: Any] = [
            "t": event.timestamp, "x": Double(point.x), "y": Double(point.y),
            "window": String(describing: type(of: self)),
            "view": view.map { String(describing: type(of: $0)) } ?? "nil",
        ]
        if view !== WindowProbe.plane, let why = WindowProbe.refusal(for: point, in: self) {
            fields["why"] = why
        }
        TypingDiagnostics.log("whit", fields)
        return view
    }

    @objc dynamic func murmurProbe_sendEvent(_ event: UIEvent) {
        if TypingDiagnostics.isOn, event.type == .touches, let touches = event.allTouches {
            for touch in touches where touch.phase == .began {
                let others = touches.filter { $0 !== touch }.map { other -> String in
                    switch other.phase {
                    case .began: "B"
                    case .moved: "M"
                    case .stationary: "S"
                    case .ended: "E"
                    case .cancelled: "C"
                    default: "?"
                    }
                }.joined()
                TypingDiagnostics.log("event", [
                    "t": touch.timestamp,
                    "window": String(describing: type(of: self)),
                    "view": touch.view.map { String(describing: type(of: $0)) } ?? "nil",
                    "others": others,
                ])
            }
        }
        murmurProbe_sendEvent(event)
    }
}
