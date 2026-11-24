import Foundation

/// The keyboard's typing engine: layout, touch handling, autocorrect, swipe and learning.
/// It has no UIKit, so the Mac tests exercise it; only the iPhone keyboard links it. The
/// word model it reads ships as a resource of this module and is reached only through
/// `TypingResources`, never through `Bundle.main`, because a keyboard extension's main bundle
/// is the extension and not the package.
public enum TypingResources {
    /// The bundled word model, or nil when the resource is missing from the module's bundle.
    public static var modelURL: URL? {
        Bundle.module.url(forResource: "en", withExtension: "mtm")
    }
}
