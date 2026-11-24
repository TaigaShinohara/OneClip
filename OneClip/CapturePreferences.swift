import Foundation

enum OnboardingValueTopic: String, CaseIterable, Equatable, Sendable {
    case collectionStack
    case annotationCallout
    case instantSingleCopy
}

enum OnboardingConcern: String, CaseIterable, Equatable, Sendable, Identifiable {
    case multi
    case explain
    case quick
    case unsure

    var id: String { rawValue }

    var optionTitle: String {
        switch self {
        case .multi: return "複数の箇所を1枚にまとめたい"
        case .explain: return "画像にコメントや囲みを付けたい"
        case .quick: return "1箇所をすぐコピーしたい"
        case .unsure: return "使いながら決めたい"
        }
    }

    var optionSymbol: String {
        switch self {
        case .multi: return "square.stack.3d.up"
        case .explain: return "text.bubble"
        case .quick: return "viewfinder"
        case .unsure: return "sparkles"
        }
    }

    var matchHeadline: String {
        switch self {
        case .multi: return "何回も貼り直しているあなたに、ぴったり"
        case .explain: return "言葉で伝わりにくいあなたに、ぴったり"
        case .quick: return "すぐ切り取って貼りたいあなたに、ぴったり"
        case .unsure: return "まずは1箇所、気軽に試すのがおすすめです"
        }
    }

    var matchSubtitle: String {
        switch self {
        case .multi: return "最大4箇所を順番に選ぶだけで、縦1枚のPNGに自動でまとまります。"
        case .explain: return "撮った直後の小画像から、吹き出しや囲みをそのまま書き込めます。"
        case .quick: return "メニューから範囲を囲んで離すだけで、コピーと保存が同時に終わります。"
        case .unsure: return "1箇所のコピーも複数箇所のまとめ撮りも、画面上のメニューからいつでも選べます。"
        }
    }

    var prefersCollection: Bool {
        self == .multi
    }

    var orderedValues: [OnboardingValueTopic] {
        switch self {
        case .multi: return [.collectionStack, .annotationCallout]
        case .explain: return [.annotationCallout, .collectionStack]
        case .quick: return [.instantSingleCopy, .collectionStack]
        case .unsure: return [.instantSingleCopy, .collectionStack]
        }
    }

    var connectionHeadline: String {
        switch self {
        case .multi: return "メニューから、最初のまとめ撮りを試す"
        case .explain: return "メニューから、最初の1枚に注釈を試す"
        case .quick, .unsure: return "メニューから、最初の範囲コピーを試す"
        }
    }

    var connectionButtonTitle: String {
        switch self {
        case .multi: return "「集めてコピー」の案内を開く"
        case .explain, .quick, .unsure: return "「範囲をコピー」の案内を開く"
        }
    }

    var initialGuideBanner: String {
        switch self {
        case .multi:
            return "おすすめ：画面上部のOneClipメニューから「集めてコピー…」を選び、2箇所を順番に囲んでみましょう。"
        case .explain:
            return "おすすめ：画面上部のOneClipメニューから「範囲をコピー」で1枚撮り、右下の小画像から「コメント・記号を追加」を試してみましょう。"
        case .quick, .unsure:
            return "おすすめ：画面上部のOneClipメニューから「範囲をコピー」を選び、伝えたい範囲をドラッグして囲んでみましょう。"
        }
    }
}

enum OnboardingTrialSample: String, CaseIterable, Equatable, Sendable, Identifiable {
    case issueArea
    case settingsValue
    case afterResult

    var id: String { rawValue }

    var title: String {
        switch self {
        case .issueArea: return "不具合の箇所"
        case .settingsValue: return "設定の項目"
        case .afterResult: return "修正後の画面"
        }
    }

    var dimensionsLabel: String {
        switch self {
        case .issueArea: return "320 × 180 px"
        case .settingsValue: return "280 × 140 px"
        case .afterResult: return "320 × 200 px"
        }
    }

    var symbol: String {
        switch self {
        case .issueArea: return "exclamationmark.bubble"
        case .settingsValue: return "slider.horizontal.3"
        case .afterResult: return "checkmark.rectangle"
        }
    }
}

enum OnboardingTelemetryEvent: Equatable, Sendable {
    case pageViewed(pageIndex: Int, role: String)
    case concernSelected(OnboardingConcern)
    case trialCompleted(OnboardingTrialSample)
    case skipped(fromPageIndex: Int)
    case closed(fromPageIndex: Int)
    case completed(concern: OnboardingConcern, sample: OnboardingTrialSample)
}

/// Only first-use acknowledgements live here. Captured images and sessions never enter defaults.
@MainActor
final class CapturePreferences {
    static let shared = CapturePreferences()
    static let currentOnboardingVersion = 1

    private let defaults: UserDefaults?
    private var captureGuideSeen: Bool
    private var collectionGuideSeen: Bool
    private var pasteHintSeen: Bool
    private var welcomeSeen: Bool
    private var onboardingVersionSeen: Int
    private var storedConcern: OnboardingConcern?
    private var storedTrialSample: OnboardingTrialSample?
    private(set) var onboardingEvents: [OnboardingTelemetryEvent] = []

    private static let guideKey = "OneClip.hasSeenCaptureGuide"
    private static let collectionGuideKey = "OneClip.hasSeenCollectionGuide"
    private static let pasteKey = "OneClip.hasSeenPasteHint"
    private static let welcomeKey = "OneClip.hasSeenWelcome"
    private static let onboardingVersionKey = "OneClip.completedOnboardingVersion"
    private static let onboardingConcernKey = "OneClip.onboardingConcern"
    private static let onboardingTrialKey = "OneClip.onboardingTrialSample"

    /// Passing nil creates an isolated, memory-only store for injected tests and Debug panels.
    init(defaults: UserDefaults? = .standard,
         hasSeenCaptureGuide: Bool = false, hasSeenPasteHint: Bool = false,
         hasSeenCollectionGuide: Bool = false, hasSeenWelcome: Bool = false,
         completedOnboardingVersion: Int = 0) {
        self.defaults = defaults
        captureGuideSeen = defaults?.object(forKey: Self.guideKey) as? Bool ?? hasSeenCaptureGuide
        collectionGuideSeen = defaults?.object(forKey: Self.collectionGuideKey) as? Bool ?? hasSeenCollectionGuide
        pasteHintSeen = defaults?.object(forKey: Self.pasteKey) as? Bool ?? hasSeenPasteHint
        welcomeSeen = defaults?.object(forKey: Self.welcomeKey) as? Bool ?? hasSeenWelcome
        onboardingVersionSeen = defaults?.object(forKey: Self.onboardingVersionKey) as? Int ?? completedOnboardingVersion
        if let rawConcern = defaults?.string(forKey: Self.onboardingConcernKey) {
            storedConcern = OnboardingConcern(rawValue: rawConcern)
        } else {
            storedConcern = nil
        }
        if let rawSample = defaults?.string(forKey: Self.onboardingTrialKey) {
            storedTrialSample = OnboardingTrialSample(rawValue: rawSample)
        } else {
            storedTrialSample = nil
        }
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

    var completedOnboardingVersion: Int {
        get { onboardingVersionSeen }
        set { onboardingVersionSeen = newValue; defaults?.set(newValue, forKey: Self.onboardingVersionKey) }
    }

    var selectedOnboardingConcern: OnboardingConcern? {
        get { storedConcern }
        set {
            storedConcern = newValue
            if let newValue {
                defaults?.set(newValue.rawValue, forKey: Self.onboardingConcernKey)
            } else {
                defaults?.removeObject(forKey: Self.onboardingConcernKey)
            }
        }
    }

    var completedOnboardingTrial: OnboardingTrialSample? {
        get { storedTrialSample }
        set {
            storedTrialSample = newValue
            if let newValue {
                defaults?.set(newValue.rawValue, forKey: Self.onboardingTrialKey)
            } else {
                defaults?.removeObject(forKey: Self.onboardingTrialKey)
            }
        }
    }

    var preferredInitialCollectionMode: Bool {
        storedConcern?.prefersCollection ?? false
    }

    /// True on initial launch when welcome was never seen, or when a previously completed onboarding version is outdated.
    var shouldPresentOnboardingOnLaunch: Bool {
        if hasSeenWelcome {
            return onboardingVersionSeen > 0 && onboardingVersionSeen < Self.currentOnboardingVersion
        }
        return onboardingVersionSeen < Self.currentOnboardingVersion
    }

    func recordOnboardingEvent(_ event: OnboardingTelemetryEvent) {
        onboardingEvents.append(event)
    }

    func recordOnboardingCompletion(concern: OnboardingConcern, trialSample: OnboardingTrialSample) {
        selectedOnboardingConcern = concern
        completedOnboardingTrial = trialSample
        completedOnboardingVersion = Self.currentOnboardingVersion
        hasSeenWelcome = true
        onboardingEvents.append(.completed(concern: concern, sample: trialSample))
    }

    func recordOnboardingSkip(fromPage pageIndex: Int) {
        completedOnboardingVersion = Self.currentOnboardingVersion
        hasSeenWelcome = true
        onboardingEvents.append(.skipped(fromPageIndex: pageIndex))
    }
}
