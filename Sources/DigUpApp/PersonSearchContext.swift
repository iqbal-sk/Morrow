import DigUpKit
import SwiftUI

struct PersonSearchContext: View {
    let context: PersonQuery

    var body: some View {
        if !context.people.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.rectangle.stack").foregroundStyle(Brand.accent)
                Text(context.people.map(\.name).joined(separator: " + "))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                Text(context.remainder.isEmpty ? "person matches" : "person matches · \(context.remainder)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Searching files that match or mention \(context.people.map(\.name).joined(separator: ", "))\(context.remainder.isEmpty ? "" : ", also matching \(context.remainder)")")
        } else if !context.ambiguous.isEmpty {
            Label("This name matches more than one person. Try a full name or unique alias.",
                  systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
        }
    }
}
