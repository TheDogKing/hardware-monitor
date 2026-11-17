import SwiftUI

/// The panel speaks in one instrument voice: SF Mono for every figure, unit and
/// label so columns align and nothing reflows as values change. CJK glyphs fall
/// back to the system face, which keeps Chinese legible at small sizes.
extension Font {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// One tint per domain, chosen to stay legible over any wallpaper.
enum Accent {
    static let cpu = Color(red: 0.36, green: 0.66, blue: 1.0)
    static let gpu = Color(red: 0.78, green: 0.55, blue: 1.0)
    static let memory = Color(red: 1.0, green: 0.70, blue: 0.42)
    static let network = Color(red: 0.42, green: 0.86, blue: 0.60)
    static let thermal = Color(red: 1.0, green: 0.52, blue: 0.52)
}

enum Panel {
    static let corner: CGFloat = 22
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 14
    static let cardWidth: CGFloat = 226
}

extension View {
    /// The card shell: Liquid Glass with a faint colour wash and the
    /// specular response to the pointer that makes the material read as glass.
    /// Fills its grid slot so rows of cards stay exactly the same size.
    func glassCard(_ tint: Color) -> some View {
        padding(Panel.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassEffect(.regular.tint(tint.opacity(0.28)).interactive(),
                         in: .rect(cornerRadius: Panel.corner))
    }
}

/// One row of equal-size cards: every slot gets the same fixed width and the
/// tallest card's ideal height is proposed to all of them, so content
/// differences cannot skew the grid.
struct EqualHeightRow: Layout {
    var spacing: CGFloat
    var cardWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var height: CGFloat = 0
        for subview in subviews {
            height = max(height, subview.sizeThatFits(.init(width: cardWidth, height: nil)).height)
        }
        let width = cardWidth * CGFloat(subviews.count)
            + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          anchor: .topLeading,
                          proposal: .init(width: cardWidth, height: bounds.height))
            x += cardWidth + spacing
        }
    }
}

/// Large figure + unit, the visual anchor of every card.
struct MetricValue: View {
    let value: String
    var unit: String?
    var font: Font = .mono(30, .semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(font)
            if let unit {
                Text(unit).font(.mono(12, .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// `label …… value` line used for all secondary metrics.
struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.mono(11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value).font(.mono(11, .medium))
                .foregroundStyle(.primary.opacity(0.92))
        }
    }
}

struct CardHeader: View {
    let title: String
    var systemImage: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(title).font(.mono(12, .semibold))
            Spacer(minLength: 0)
        }
    }
}
