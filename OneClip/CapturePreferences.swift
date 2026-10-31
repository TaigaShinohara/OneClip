import Foundation

/// Only first-use acknowledgements live here. Captured images and sessions never enter defaults.
@MainActor
final class CapturePreferences {
    static let shared = CapturePreferences()
    private let defaults: UserDefaults?
    private var captureGuideSeen: Bool
    private var collectionGuideSeen: Bool
    private var pasteHintSeen: Bool
    private var welcomeSeen: Bool
    private static let guideKey = "OneClip.hasSeenCaptureGuide"
    private static let collectionGuideKey = "OneClip.hasSeenCollectionGuide"
    private static let pasteKey = "OneClip.hasSeenPasteHint"
    private static let welcomeKey = "OneClip.hasSeenWelcome"

    /// Passing nil creates an isolated, memory-only store for injected tests and Debug panels.
    init(defaults: UserDefaults? = .standard,
         hasSeenCaptureGuide: Bool = false, hasSeenPasteHint: Bool = false,
         hasSeenCollectionGuide: Bool = false, hasSeenWelcome: Bool = false) {
        self.defaults = defaults
        captureGuideSeen = defaults?.object(forKey: Self.guideKey) as? Bool ?? hasSeenCaptureGuide
        collectionGuideSeen = defaults?.object(forKey: Self.collectionGuideKey) as? Bool ?? hasSeenCollectionGuide
        pasteHintSeen = defaults?.object(forKey: Self.pasteKey) as? Bool ?? hasSeenPasteHint
        welcomeSeen = defaults?.object(forKey: Self.welcomeKey) as? Bool ?? hasSeenWelcome
    }

    /// Existing users already acknowledged an introduction. Do not interrupt them after upgrading.
    var hasSeenWelcome: Bool {
        get { welcomeSeen || captureGuideSeen || collectionGuideSeen }
        set { welcomeSeen = newValue; defaults?.set(newValue, forKey: Self.welcomeKey) }
    }

    var hasSeenCaptureGuide: Bool {
        get { captureGuideSeen }
        set { captureGuideSeen = newValue; defaults?.set(newValue, forKey: Self.guideKey) }
    }

    var hasSeenPasteHint: Bool {
        get { pasteHintSeen }
        set { pasteHintSeen = newValue; defaults?.set(newValue, forKey: Self.pasteKey) }
    }

    var hasSeenCollectionGuide: Bool {
        get { collectionGuideSeen }
        set { collectionGuideSeen = newValue; defaults?.set(newValue, forKey: Self.collectionGuideKey) }
    }
}
