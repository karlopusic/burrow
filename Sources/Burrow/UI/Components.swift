import SwiftUI
import AppKit

/// Shared visual building blocks, so every screen uses the same surfaces, spacing and status colors.
enum Theme {
    static let radius: CGFloat = 12
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
}

struct CardModifier: ViewModifier {
    var tint: Color?
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    shape.fill(Theme.surface)
                    if let tint { shape.fill(tint.opacity(0.08)) }
                }
            }
            .overlay { shape.strokeBorder(tint.map { $0.opacity(0.25) } ?? Theme.hairline, lineWidth: 1) }
    }
}

extension View {
    /// A raised rounded surface on the window background (like a grouped Form section).
    func card(tint: Color? = nil, padding: CGFloat = 16) -> some View {
        modifier(CardModifier(tint: tint, padding: padding))
    }
}

/// A white SF Symbol on a colored rounded square, like the icons in System Settings.
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Small colored capsule label ("scheduled", "preview", …).
struct StatusPill: View {
    let text: Text
    let tint: Color

    var body: some View {
        text.font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

/// A key figure with an icon, e.g. "Next backup · Tomorrow 21:00".
struct StatTile: View {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let value: Text
    var detail: Text? = nil
    /// 0…1 – draws a capacity bar under the value.
    var gauge: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconBadge(systemImage: systemImage, tint: tint, size: 22)
                Text(title).font(.subheadline).foregroundStyle(.secondary)
            }
            value.font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
            if let gauge {
                ProgressView(value: min(max(gauge, 0), 1))
                    .tint(gauge > 0.9 ? .red : gauge > 0.75 ? .orange : tint)
            }
            if let detail { detail.font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card(padding: 14)
    }
}

/// Section title used above cards.
struct SectionTitle<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: LocalizedStringKey) { self.init(title: title) { EmptyView() } }
}

/// Transient message at the bottom of the main window.
struct Toast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(text)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
