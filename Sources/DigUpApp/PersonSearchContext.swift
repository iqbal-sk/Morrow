import DigUpKit
import SwiftUI

struct PersonSearchContext: View {
    let context: PersonQuery
    var body: some View {
        if !context.people.isEmpty {
            HStack(spacing: 8) {
                Label(context.people.map(\.name).joined(separator: " + "), systemImage: "person.crop.rectangle.stack")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
                Text("Face matches & text mentions").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(.vertical, 6).accessibilityElement(children: .combine)
        } else if !context.ambiguous.isEmpty {
            Label("Shared name: use a full name or a unique alias.", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
        }
    }
}
