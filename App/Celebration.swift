import SwiftUI
import DADFoundation

// The celebration shown once after a donor's first gift completes. Motion is reduce-motion-gated
// and only the check scales in; numbers never animate.

/// Shown as a full-screen cover after the first gift is set up. "Invite someone" routes to Circle;
/// "Done" dismisses. Under Reduce Motion it appears with no animation at all.
struct CelebrationView: View {
    /// The monthly label, e.g. "$30/month".
    let monthly: String
    /// The per-day label, e.g. "$1 a day".
    let daily: String
    /// Whether to show the single Founding Donor capsule (the one Founding mention on this screen).
    let founding: Bool
    let onInvite: () -> Void
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkShown = false
    @ScaledMetric(relativeTo: .largeTitle) private var checkSize: CGFloat = 72

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: checkSize))
                        .foregroundStyle(Color.dad("ok"))
                        .accessibilityLabel("Gift set up")
                        // Single spring scale-in of the check ONLY, and only when motion is allowed.
                        .scaleEffect(reduceMotion ? 1 : (checkShown ? 1 : 0.6))
                        .opacity(reduceMotion ? 1 : (checkShown ? 1 : 0))
                    VStack(spacing: 12) {
                        Text("You’re in. Welcome to the beginning.")
                            .font(.dadDisplay(.largeTitle, size: 30)).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        DADGiftFraming(monthly: monthly, daily: daily)
                        if founding {
                            Label("Founding donor", systemImage: "star.fill").font(.footnote.weight(.semibold))
                                .padding(.horizontal, .dadSpace("3")).padding(.vertical, .dadSpace("1"))
                                .background(Color.dad("ok-ink"), in: Capsule())
                                .foregroundStyle(Color.dad("paper"))
                                .accessibilityIdentifier("celebration-founding")
                        }
                    }
                    VStack(spacing: 12) {
                        Button("Invite someone", action: onInvite)
                            .buttonStyle(DADButtonStyle(.primary)).accessibilityIdentifier("celebration-invite")
                        Button("Done", action: onDone)
                            .buttonStyle(DADButtonStyle(.tertiary)).accessibilityIdentifier("celebration-done")
                    }
                }
                .frame(maxWidth: 520, alignment: .center).padding(28)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                // On the content, not the ScrollView: UITests find the screen as a plain container.
                .accessibilityElement(children: .contain).accessibilityIdentifier("celebration-screen")
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.dad("ink-deep").ignoresSafeArea())
        .foregroundStyle(Color.dad("paper"))
        .onAppear {
            guard !reduceMotion else { checkShown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { checkShown = true }
        }
    }
}
