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
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(InkwellPalette.parchment)
                    .listRowSeparator(.hidden)
                }
                ForEach(Array(store.inklings.enumerated()), id: \.element.id) { index, inkling in
                    row(for: inkling, tinted: index.isMultiple(of: 2))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(InkwellPalette.parchment)
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

    private func row(for inkling: Inkling, tinted: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
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
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            Rectangle()
                .fill(InkwellPalette.ink.opacity(0.12))
                .frame(height: 1)
                .padding(.leading, 16)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(tinted ? InkwellPalette.parchmentDeep : InkwellPalette.parchment)
        .listRowSeparator(.hidden)
    }
}

#Preview {
    ListView(store: InklingStore())
}
