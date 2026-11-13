import SwiftUI
import AppKit

// MARK: - Pointing-hand cursor

/// Shows the pointing hand while the mouse is over the view.
struct PointerCursorModifier: ViewModifier {
    var enabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? PointerStyle.link : nil)
        } else {
            content
                .onHover { inside in
                    guard enabled else { return }
                    if inside && !pushed {
                        NSCursor.pointingHand.push()
                        pushed = true
                    } else if !inside && pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onDisappear {
                    // Never leave the hand stuck on screen if the view goes away while hovered.
                    if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
        }
    }
}

extension View {
    /// Pointing-hand cursor on hover. Pass `false` to turn it off (for example when disabled).
    func pointerCursor(_ enabled: Bool = true) -> some View {
        modifier(PointerCursorModifier(enabled: enabled))
    }
}

// MARK: - Button style

/// One look for every button: a hover highlight, a pressed state, a dimmed disabled state,
/// and the pointing-hand cursor.
struct AppButtonStyle: ButtonStyle {
    enum Kind {
        /// Subtle filled button (the default).
        case bordered
        /// Accent-colored main action.
        case prominent
        /// No chrome; a soft highlight on hover.
        case plain
        /// For large clickable cards that bring their own background.
        case card
        /// Small round button, such as a close or remove "x".
        case icon
        /// Text that looks like a link.
        case link
    }

    let kind: Kind

    init(_ kind: Kind = .bordered) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var hot: Bool { hovering && isEnabled }
        private var pressed: Bool { configuration.isPressed }

        private var padding: EdgeInsets {
            guard kind == .bordered || kind == .prominent else { return EdgeInsets() }
            switch controlSize {
            case .mini: return EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
            case .small: return EdgeInsets(top: 3, leading: 9, bottom: 3, trailing: 9)
            case .large: return EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
            default: return EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12)
            }
        }

        private var fontSize: CGFloat {
            guard kind == .bordered || kind == .prominent else { return 13 }
            switch controlSize {
            case .mini: return 10
            case .small: return 12
            case .large: return 14
            default: return 13
            }
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: kind == .card ? 14 : 7, style: .continuous)
        }

        @ViewBuilder
        private var background: some View {
            switch kind {
            case .bordered:
                shape.fill(Color.primary.opacity(pressed ? 0.20 : (hot ? 0.14 : 0.08)))
            case .prominent:
                shape.fill(Color.accentColor.opacity(pressed ? 0.72 : (hot ? 0.88 : 1)))
            case .plain:
                shape.fill(Color.primary.opacity(pressed ? 0.14 : (hot ? 0.08 : 0)))
            case .icon:
                Circle().fill(Color.primary.opacity(pressed ? 0.20 : (hot ? 0.12 : 0)))
            case .card, .link:
                Color.clear
            }
        }

        var body: some View {
            let label = configuration.label
                .font(.system(size: fontSize, weight: kind == .prominent ? .medium : .regular))
                .padding(padding)
                .frame(minWidth: kind == .icon ? 22 : nil, minHeight: kind == .icon ? 22 : nil)

            Group {
                switch kind {
                case .prominent:
                    label.foregroundStyle(Color.white)
                case .link:
                    label.foregroundStyle(Color.accentColor).opacity(hot ? 0.7 : 1)
                case .icon:
                    label.foregroundStyle(hot ? Color.primary : Color.secondary)
                default:
                    label
                }
            }
            .background(background)
            .overlay(
                Group {
                    if kind == .bordered {
                        shape.strokeBorder(Color.primary.opacity(0.10))
                    } else if kind == .card {
                        shape.strokeBorder(Color.accentColor.opacity(hot ? 0.6 : 0), lineWidth: 1.5)
                    }
                }
            )
            .shadow(color: .black.opacity(kind == .card && hot ? 0.12 : 0), radius: 8, x: 0, y: 3)
            .scaleEffect(pressed ? (kind == .card ? 0.985 : 0.97) : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(kind == .icon ? AnyShape(Circle()) : AnyShape(shape))
            .onHover { hovering = $0 }
            .pointerCursor(isEnabled)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: pressed)
        }
    }
}

// MARK: - Transparency grid

/// The classic light checkerboard that stands for "transparent". It goes behind pictures that can have
/// see-through areas, so those areas are easy to tell from white.
struct TransparencyGrid: View {
    var cell: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let rows = Int((size.height / cell).rounded(.up))
            let columns = Int((size.width / cell).rounded(.up))
            guard rows > 0, columns > 0 else { return }
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let square = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(square), with: .color(Color(white: 0.9)))
                }
            }
        }
    }
}

// MARK: - Slider without tick marks

/// A slider that moves in whole numbers. `Slider(step:)` draws a tick mark for every step, which looks
/// like a row of dots under the slider, so this rounds the value itself instead.
struct WholeNumberSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: range)
    }
}
