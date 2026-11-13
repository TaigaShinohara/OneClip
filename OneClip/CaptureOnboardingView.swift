import AppKit
import SwiftUI

/// First-run onboarding, shown once instead of the usage guide.
/// One claim per page: hook, use-case choice, match, identity, three values,
/// three steps, a small trial, the recording-permission reason, and a hand-off
/// that starts the first capture. The usage guide remains the re-readable reference.
/// macOS has no haptic feedback, so reactions are animation plus wording only.
enum CaptureOnboarding {
    static let version = 1
}

enum WelcomeUseCase: CaseIterable {
    case consultPerson
    case consultAI
    case beforeAfter
    case undecided

    var label: String {
        switch self {
        case .consultPerson: return "エラーや不具合を、誰かに相談したい"
        case .consultAI: return "AIに画面を見せて、相談したい"
        case .beforeAfter: return "変更の前と後を、見せたい"
        case .undecided: return "まだわからない"
        }
    }

    var symbol: String {
        switch self {
        case .consultPerson: return "exclamationmark.bubble"
        case .consultAI: return "sparkles"
        case .beforeAfter: return "photo.stack"
        case .undecided: return "questionmark.circle"
        }
    }

    /// The one strength that answers this use case directly, shown on the match page.
    var strength: String {
        switch self {
        case .consultPerson: return "複数箇所を1枚にまとめて、状況を一度で伝えられます。"
        case .consultAI: return "コメントと記号で、見てほしい所を指し示せます。"
        case .beforeAfter: return "前と後を撮影順に並べて、1枚で比べられます。"
        case .undecided: return "選んで離すだけ。いちばん軽い使い方から始められます。"
        }
    }

    var matchHeadline: String {
        switch self {
        case .undecided: return "まずは、1枚からで大丈夫です"
        default: return "そんなあなたには、OneClipがぴったりです"
        }
    }
}

private enum WelcomeValue {
    case fast, collect, annotate
}

private enum WelcomePage: Equatable {
    case hook, choice, match, identity
    case value(WelcomeValue)
    case step(Int)
    case trial, trialResult, permission, connect

    /// Name announced to VoiceOver instead of a page count.
    var voiceName: String {
        switch self {
        case .hook: return "はじめに"
        case .choice: return "使いたい場面の質問"
        case .match: return "質問への返答"
        case .identity: return "このアプリについて"
        case .value: return "できること"
        case .step(let number): return "使い方の手順 \(number)つ目"
        case .trial: return "試し操作"
        case .trialResult: return "試し操作の結果"
        case .permission: return "画面収録の許可について"
        case .connect: return "始める準備"
        }
    }
}

struct CaptureOnboardingView: View {
    /// true starts the first single capture as soon as the window closes.
    let finished: (Bool) -> Void

    @State private var index = 0
    @State private var choice: WelcomeUseCase?
    @State private var praise: String?
    @State private var lastPraise: String?
    @State private var advancing = false
    @State private var trialStart: CGPoint?
    @State private var trialCurrent: CGPoint?
    @State private var trialHint = false
    @State private var celebrate = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var valueOrder: [WelcomeValue] {
        switch choice {
        case .consultPerson: return [.collect, .annotate, .fast]
        case .consultAI: return [.annotate, .collect, .fast]
        case .beforeAfter: return [.collect, .fast, .annotate]
        case .undecided, nil: return [.fast, .collect, .annotate]
        }
    }

    private var pages: [WelcomePage] {
        [.hook, .choice, .match, .identity]
            + valueOrder.map(WelcomePage.value)
            + [.step(1), .step(2), .step(3), .trial, .trialResult, .permission, .connect]
    }

    private var page: WelcomePage { pages[index] }

    private var showsNextButton: Bool {
        switch page {
        case .choice, .trial, .connect: return false
        default: return true
        }
    }

    private var nextTitle: String {
        switch page {
        case .permission: return "わかりました"
        case .trialResult: return "進む"
        default: return "次へ"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if index > 0 {
                    Button("戻る") { goBack() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                Button("スキップ") { finished(false) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .frame(height: 22)

            ZStack {
                pageContent(page)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 408)
            .padding(.top, 10)

            ZStack {
                if let praise {
                    Text(praise)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(OneClipTone.collection.color(for: colorScheme).opacity(0.16)))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(height: 36)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: praise)

            HStack(alignment: .center) {
                WelcomeDots(total: pages.count, current: index)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("いまのページ: \(page.voiceName)")
                Spacer()
                if showsNextButton {
                    Button(nextTitle) { goNext() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule).controlSize(.large)
                        .tint(OneClipTone.single.color(for: colorScheme))
                }
            }
            .padding(.top, 6)
        }
        .oneClipWindow()
        .frame(width: 540)
        .background { ambientBackground }
    }

    /// Two soft shapes breathing very slowly. Stilled on the permission page,
    /// where calm matters more than atmosphere, and under Reduce Motion.
    @ViewBuilder
    private var ambientBackground: some View {
        if page != .permission, !reduceMotion {
            ZStack {
                Circle().fill(OneClipTone.single.color(for: colorScheme).opacity(0.07))
                    .frame(width: 300, height: 300).offset(x: -210, y: -190)
                Circle().fill(OneClipTone.collection.color(for: colorScheme).opacity(0.07))
                    .frame(width: 260, height: 260).offset(x: 220, y: 200)
            }
            .modifier(BreathingModifier())
            .allowsHitTesting(false)
        }
    }

    // MARK: - Navigation and reactions

    private func goNext() {
        guard index < pages.count - 1 else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.85)) {
            index += 1
        }
        if pages[index] == .connect { celebrate = true }
    }

    private func goBack() {
        guard index > 0, !advancing else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.85)) {
            index -= 1
        }
    }

    private func pickPraise(_ variants: [String]) -> String {
        let options = variants.filter { $0 != lastPraise }
        let picked = options.randomElement() ?? variants[0]
        lastPraise = picked
        return picked
    }

    private func showPraise(_ text: String) {
        praise = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            if praise == text { praise = nil }
        }
    }

    private func select(_ useCase: WelcomeUseCase) {
        guard !advancing else { return }
        advancing = true
        choice = useCase
        showPraise(pickPraise([
            "いい選び方です",
            "教えてくれてありがとう",
            "それがいちばん伝わる使い方です",
            "その場面、OneClipの得意分野です",
        ]))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 340))
            goNext()
            advancing = false
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private func pageContent(_ page: WelcomePage) -> some View {
        switch page {
        case .hook: hookPage
        case .choice: choicePage
        case .match: matchPage
        case .identity: identityPage
        case .value(let value): valuePage(value)
        case .step(let number): stepPage(number)
        case .trial: trialPage
        case .trialResult: trialResultPage
        case .permission: permissionPage
        case .connect: connectPage
        }
    }

    private func headline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 24, weight: .semibold, design: .rounded))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(.callout).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scaffold<Visual: View>(headline headlineText: String, subline sublineText: String?,
                                         @ViewBuilder visual: () -> Visual) -> some View {
        VStack(spacing: 16) {
            visual()
                .frame(height: 208)
                .frame(maxWidth: .infinity)
            headline(headlineText)
            if let sublineText { subline(sublineText) }
            Spacer(minLength: 0)
        }
    }

    private var hookPage: some View {
        scaffold(headline: "見せたいところだけ、渡せたら。",
                 subline: "必要なところだけを選んで、相手に渡せます。") {
            MockScreen(selectionAnimated: true)
        }
    }

    private var choicePage: some View {
        VStack(spacing: 16) {
            headline("どんな場面で使いたいですか")
            subline("いちばん近いものを、ひとつ選んでください。")
            VStack(spacing: 10) {
                ForEach(WelcomeUseCase.allCases, id: \.label) { useCase in
                    Button { select(useCase) } label: {
                        HStack(spacing: 14) {
                            OneClipBadge(systemName: useCase.symbol,
                                         tone: choice == useCase ? .collection : .single, size: 40)
                            Text(useCase.label).font(.body.weight(.medium))
                            Spacer(minLength: 0)
                        }
                        .oneClipCard(padding: 14)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(choice == useCase ? 1.03 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: choice)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var matchPage: some View {
        scaffold(headline: choice?.matchHeadline ?? "そんなあなたには、OneClipがぴったりです",
                 subline: choice?.strength) {
            VStack(spacing: 10) {
                if let choice, choice != .undecided {
                    Text("「\(choice.label)」")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                MockClipboard(count: 3)
            }
        }
    }

    private var identityPage: some View {
        scaffold(headline: "必要なところを集めて、ひと貼り。",
                 subline: "OneClipは、画面の一部を切り取って渡すためのアプリです。") {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OneClipTone.single.color(for: colorScheme), lineWidth: 2.5)
                    .frame(width: 120, height: 84)
                    .offset(x: -38, y: -16)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(OneClipTone.collection.color(for: colorScheme), lineWidth: 2.5)
                    .frame(width: 120, height: 84)
                    .offset(x: 38, y: 22)
                Image(systemName: "paperclip")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
    }

    @ViewBuilder
    private func valuePage(_ value: WelcomeValue) -> some View {
        switch value {
        case .fast:
            scaffold(headline: "選び終わったら、もうコピーされています",
                     subline: "単発なら、ドラッグして離すだけ。確認画面は挟みません。") {
                MockScreen(selectionAnimated: false)
            }
        case .collect:
            scaffold(headline: "複数箇所も、1枚にまとまります",
                     subline: "最大4枚まで、撮影順に縦に並びます。") {
                MockClipboard(count: 3)
            }
        case .annotate:
            scaffold(headline: "見てほしい所を、指し示せます",
                     subline: "吹き出し・囲み・番号を、画像の中に置けます。") {
                MockAnnotation()
            }
        }
    }

    private func stepPage(_ number: Int) -> some View {
        let headlineText: String
        let sublineText: String
        if number == 1 {
            headlineText = "メニューから始める"
            sublineText = "画面上部のOneClipメニューから「範囲をコピー」を選びます。キーも設定できます。"
        } else if number == 2 {
            headlineText = "ドラッグで範囲を選ぶ"
            sublineText = "見せたい部分を囲みます。矢印キーで微調整もできます。"
        } else {
            headlineText = "離すとコピー、そのまま貼れる"
            sublineText = "確定した画像はコピー済み。Command+Vで相手に渡せます。"
        }
        return scaffold(headline: headlineText, subline: sublineText) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(OneClipTone.single.color(for: colorScheme))
                        .frame(width: 58, height: 58)
                    Text("\(number)").font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .modifier(PulseModifier())
                Image(systemName: number == 1 ? "menubar.rectangle" : (number == 2 ? "cursorarrow.click.2" : "doc.on.clipboard"))
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trialPage: some View {
        VStack(spacing: 16) {
            headline("ここで一度、囲んでみましょう")
            subline(trialHint ? "もう少し大きく囲むと、うまくいきます。" : "下の画面の中で、ドラッグして範囲を囲んでください。")
            TrialStage(start: $trialStart, current: $trialCurrent) { rect in
                completeTrial(rect)
            }
            .frame(height: 190)
            Spacer(minLength: 0)
        }
    }

    private func completeTrial(_ rect: CGRect) {
        guard !advancing else { return }
        if rect.width > 70, rect.height > 44 {
            advancing = true
            showPraise(pickPraise([
                "その調子です",
                "きれいに囲めました",
                "もう基本はつかめています",
            ]))
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 120 : 360))
                goNext()
                advancing = false
            }
        } else {
            trialHint = true
        }
    }

    private var trialResultPage: some View {
        scaffold(headline: "できました。それが基本の動きです",
                 subline: "本番でも、囲んで離すだけでコピーされます。") {
            MockClipboard(count: 1)
        }
    }

    private var permissionPage: some View {
        scaffold(headline: "画面を撮るには、許可が要ります",
                 subline: "OneClipが画面の一部を読み取るために、macOSの「画面収録」の許可が必要です。最初の撮影のときに案内します。許可しないと撮影は始まりません。") {
            Image(systemName: "lock.shield")
                .font(.system(size: 76, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var connectPage: some View {
        VStack(spacing: 16) {
            ZStack {
                Image(systemName: "paperclip.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(OneClipTone.collection.color(for: colorScheme))
                if celebrate, !reduceMotion {
                    CelebrationBurst()
                }
            }
            .frame(height: 150)
            headline("準備ができました")
            subline(connectHint)
            VStack(spacing: 10) {
                Button("最初の範囲を選んでみる") { finished(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule).controlSize(.large)
                    .tint(OneClipTone.single.color(for: colorScheme))
                Button("あとで始める") { finished(false) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .onAppear { celebrate = true }
    }

    private var connectHint: String {
        switch choice {
        case .consultPerson, .consultAI, .beforeAfter:
            return "あなたには「集めてコピー」も合います。2回目から試せます。まずは軽い単発から。"
        case .undecided, nil:
            return "まずは「範囲をコピー」で、最初の1枚を撮ってみましょう。"
        }
    }
}

/// Sliding window of at most five dots. The total page count is never shown.
private struct WelcomeDots: View {
    let total: Int
    let current: Int

    private var visible: [Int] {
        guard total > 5 else { return Array(0..<total) }
        let start = min(max(current - 2, 0), total - 5)
        return Array(start..<(start + 5))
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(visible, id: \.self) { position in
                Circle()
                    .fill(position == current ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: size(for: position), height: size(for: position))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
    }

    private func size(for position: Int) -> CGFloat {
        if position == current { return 9 }
        if total > 5 {
            if position == visible.first, position > 0 { return 5 }
            if position == visible.last, position < total - 1 { return 5 }
        }
        return 7
    }
}

/// Very slow, small breathing for ambient shapes only. Never applied to content.
private struct BreathingModifier: ViewModifier {
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(phase ? 1.03 : 1)
            .opacity(phase ? 1 : 0.82)
            .onAppear {
                withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { phase = true }
            }
    }
}

/// A gentle pulse for the one element a page wants looked at.
private struct PulseModifier: ViewModifier {
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (phase ? 1.07 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { phase = true }
            }
    }
}

/// A schematic screen with a dashed selection. Shapes only; never a real capture.
private struct MockScreen: View {
    let selectionAnimated: Bool
    @State private var drawn = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<4) { row in
                    Capsule().fill(Color.primary.opacity(0.13))
                        .frame(width: CGFloat(210 - row * 26), height: 7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            Rectangle()
                .fill(OneClipTone.single.color(for: colorScheme).opacity(0.12))
                .overlay(Rectangle().stroke(OneClipTone.single.color(for: colorScheme),
                                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .frame(width: 150, height: 92)
                .scaleEffect(drawn || !selectionAnimated ? 1 : 0.55)
                .opacity(drawn || !selectionAnimated ? 1 : 0)
                .padding(.trailing, 34).padding(.bottom, 26)
            Image(systemName: "cursorarrow")
                .font(.system(size: 22))
                .padding(.trailing, 20).padding(.bottom, 12)
        }
        .frame(width: 320, height: 190)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.primary.opacity(0.22)))
        .onAppear {
            guard selectionAnimated else { return }
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.7).delay(0.15)) {
                drawn = true
            }
        }
    }
}

/// A clipboard mock whose stacked images settle in on appear.
private struct MockClipboard: View {
    let count: Int
    @State private var settled = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Image(systemName: "clipboard")
                .font(.system(size: 128, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.55))
            VStack(spacing: 5) {
                ForEach(0..<count, id: \.self) { row in
                    Rectangle()
                        .fill(OneClipTone.collection.color(for: colorScheme).opacity(0.3))
                        .frame(width: 52, height: count == 1 ? 56 : 24)
                        .offset(y: settled ? 0 : CGFloat(-14 + row * 10))
                        .opacity(settled ? 1 : 0)
                }
            }
            .padding(.top, 12)
        }
        .frame(height: 180)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                settled = true
            }
        }
    }
}

/// An image mock with a callout and a number badge appearing on it.
private struct MockAnnotation: View {
    @State private var shown = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 300, height: 170)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.22)))
            Rectangle()
                .stroke(Color(red: 0.88, green: 0.08, blue: 0.12), lineWidth: 2.5)
                .frame(width: 108, height: 62)
                .offset(x: 36, y: 56)
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color(red: 0.88, green: 0.08, blue: 0.12))
                        .frame(width: 24, height: 24)
                    Text("1").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                Text("ここを見て")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }
            .offset(x: 158, y: 44)
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .frame(width: 300, height: 170)
        .onAppear {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.65).delay(0.25)) {
                shown = true
            }
        }
    }
}

/// The trial stage: drag inside a fake screen to draw a selection rectangle.
private struct TrialStage: View {
    @Binding var start: CGPoint?
    @Binding var current: CGPoint?
    let ended: (CGRect) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(OneClipTone.warning.color(for: colorScheme))
                        Text("エラーが表示された画面（架空）")
                            .font(.callout.weight(.medium))
                    }
                    ForEach(0..<3) { row in
                        Capsule().fill(Color.primary.opacity(0.13))
                            .frame(width: CGFloat(230 - row * 34), height: 7)
                    }
                }
                .padding(18)
                if let rect {
                    Rectangle()
                        .fill(OneClipTone.single.color(for: colorScheme).opacity(0.13))
                        .overlay(Rectangle().stroke(OneClipTone.single.color(for: colorScheme),
                                                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.22)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if start == nil { start = value.startLocation }
                        current = value.location
                    }
                    .onEnded { value in
                        let final = CGRect(
                            x: min(value.startLocation.x, value.location.x),
                            y: min(value.startLocation.y, value.location.y),
                            width: abs(value.location.x - value.startLocation.x),
                            height: abs(value.location.y - value.startLocation.y))
                        start = nil
                        current = nil
                        ended(final)
                    }
            )
            .accessibilityLabel("試し操作の画面")
            .accessibilityHint("ドラッグで範囲を囲みます")
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// One short burst of small shapes on the final page. It never blocks input.
private struct CelebrationBurst: View {
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { position in
                Circle()
                    .fill(position.isMultiple(of: 2)
                          ? OneClipTone.collection.color(for: colorScheme)
                          : OneClipTone.single.color(for: colorScheme))
                    .frame(width: 8, height: 8)
                    .offset(x: expanded ? CGFloat(cos(Double(position) * .pi / 4) * 74) : 0,
                            y: expanded ? CGFloat(sin(Double(position) * .pi / 4) * 74) : 0)
                    .opacity(expanded ? 0 : 1)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { expanded = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
