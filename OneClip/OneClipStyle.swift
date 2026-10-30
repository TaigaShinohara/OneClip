import AppKit
import SwiftUI

/// Small presentation primitives shared by the product's windows. No interaction or capture state.
enum OneClipTone {
    case single, collection, neutral, warning

    func color(for scheme: ColorScheme) -> Color {
        switch self {
        case .single:
            return scheme == .dark
                ? Color(red: 0.62, green: 0.68, blue: 1)
                : Color(red: 0.32, green: 0.39, blue: 0.76)
        case .collection:
            return scheme == .dark
                ? Color(red: 0.46, green: 0.80, blue: 0.74)
                : Color(red: 0.13, green: 0.46, blue: 0.42)
        case .neutral:
            return .secondary
        case .warning:
            return scheme == .dark
                ? Color(red: 1, green: 0.73, blue: 0.40)
                : Color(red: 0.63, green: 0.36, blue: 0.08)
        }
    }
}

struct OneClipBadge: View {
    let systemName: String
    let tone: OneClipTone
    var size: CGFloat = 46
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 21 / 46, weight: .medium))
            .foregroundStyle(tone.color(for: scheme))
            .frame(width: size, height: size)
            .background {
                Circle().fill(
                    LinearGradient(colors: [tone.color(for: scheme).opacity(0.16),
                                            tone.color(for: scheme).opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .accessibilityHidden(true)
    }
}

struct OneClipHeading: View {
    let title: String
    var subtitle: String? = nil
    let systemName: String
    let tone: OneClipTone

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            OneClipBadge(systemName: systemName, tone: tone)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OneClipCard: ViewModifier {
    let padding: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.045) : Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.07 : 0.035), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.035))
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func oneClipCard(padding: CGFloat = 20) -> some View {
        modifier(OneClipCard(padding: padding))
    }

    func oneClipWindow(padding: CGFloat = 28) -> some View {
        self.padding(padding).background(Color(nsColor: .windowBackgroundColor))
    }
}
