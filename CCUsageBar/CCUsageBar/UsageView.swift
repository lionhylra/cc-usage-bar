import SwiftUI
import AppKit

struct UsageView: View {
    @ObservedObject var viewModel: UsageViewModel

    private static let bgColor = Color(nsColor: NSColor(red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1))

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                Self.bgColor.ignoresSafeArea()

            case .loading:
                ZStack {
                    Self.bgColor
                    ProgressView("Loading usage\u{2026}")
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                        .foregroundStyle(.white)
                        .colorScheme(.dark)
                }

            case .loaded(let attributed):
                TerminalTextView(attributedText: attributed)

            case .rateLimited:
                ZStack {
                    Self.bgColor
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text("Rate Limited")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.white)
                        Text("Usage data is temporarily unavailable.\nPlease wait a moment and try again.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .needsSetup:
                ZStack {
                    Self.bgColor
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.yellow)
                        Text("Setup Required")
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.white)
                        Text("Please run `claude` in your terminal\nto log in and complete setup first.")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

            case .error(let message):
                ZStack(alignment: .topLeading) {
                    Self.bgColor
                    ScrollView {
                        Text("Error: \(message)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(width: 560, height: 230)
    }
}
