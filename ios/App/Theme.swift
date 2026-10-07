import SwiftUI
import UIKit

struct IOSHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.caption).tracking(1.4).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IOSCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    init(title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Horizontal deviation meter, ±50 cents, centred on the target.
struct CentsMeter: View {
    let cents: Double?
    let inTune: Bool
    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = max(-50.0, min(50.0, cents ?? 0))
            let position = cents == nil ? width / 2 : width / 2 + CGFloat(clamped) / 50 * width / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: width, height: 10)
                    .offset(y: 8)
                Rectangle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 1, height: 26)
                    .offset(x: width / 2)
                Circle()
                    .fill(cents == nil ? Color.secondary.opacity(0.5) : (inTune ? Color.green : Color.orange))
                    .frame(width: 16, height: 16)
                    .offset(x: max(0, min(width - 16, position - 8)), y: 5)
            }
        }
        .frame(height: 26)
        .accessibilityLabel(cents.map { String(format: "偏差 %.0f 音分", $0) } ?? "等待读数")
    }
}

/// Live capture level, 0–1 mapped to the meter width.
struct LevelBar: View {
    let level: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color(UIColor.tertiarySystemFill))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.green)
                    .frame(width: proxy.size.width * CGFloat(max(0, min(1, level * 5))))
            }
        }
        .frame(height: 6)
    }
}

struct FretDots: View {
    /// String 1 (highest) to string 6, nil means muted.
    let frets: [Int?]
    let fingers: [Int?]
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                ForEach((1...6).reversed(), id: \.self) { string in
                    Text(frets[string - 1].map { $0 == 0 ? "O" : "\($0)" } ?? "×")
                        .font(.caption.monospacedDigit())
                        .frame(width: 22)
                }
            }
            HStack(spacing: 10) {
                ForEach((1...6).reversed(), id: \.self) { string in
                    Text(fingers[string - 1].map { "\($0)" } ?? " ")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                }
            }
        }
    }
}
