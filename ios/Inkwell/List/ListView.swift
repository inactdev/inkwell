import SwiftUI

/// Just enough to see captures landing and prove sync - title, date, and a
/// plain indicator for anything not yet handed to the backend. Not the real
/// browse experience; another lane builds that.
struct ListView: View {
    let store: InklingStore
    @Environment(\.dismiss) private var dismiss

    private var unsyncedCount: Int {
        store.inklings.filter { !$0.isSynced }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.inklings.isEmpty {
                    Section {
                        HStack {
                            Text(unsyncedCount == 0 ? "All synced" : "\(unsyncedCount) not yet synced")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                ForEach(store.inklings) { inkling in
                    row(for: inkling)
                }
            }
            .listStyle(.plain)
            .overlay {
                if store.inklings.isEmpty {
                    ContentUnavailableView(
                        "The well is empty",
                        systemImage: "drop",
                        description: Text("Captures will land here.")
                    )
                }
            }
            .navigationTitle("The well")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func row(for inkling: Inkling) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(inkling.title)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(InkwellPalette.ink)
                Text(inkling.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !inkling.isSynced {
                HStack(spacing: 4) {
                    Circle()
                        .fill(InkwellPalette.amber)
                        .frame(width: 6, height: 6)
                    Text("not yet synced")
                        .font(.caption2)
                        .foregroundStyle(InkwellPalette.amber)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ListView(store: InklingStore())
}
