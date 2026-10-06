import RadianCore
import SwiftUI

/// Closed and auto-archived tabs, newest first. Clicking one brings it back.
struct ArchiveView: View {
    @Environment(BrowserStore.self) private var store
    @State private var query = ""

    private static let archiveOptions: [(label: String, hours: Double?)] = [
        ("12 hours", 12), ("24 hours", 24), ("7 days", 168), ("30 days", 720), ("Never", nil),
    ]

    var body: some View {
        let entries = filteredEntries

        VStack(spacing: 0) {
            HStack {
                Text("Archive")
                    .font(.headline)
                Spacer()
                Button("Done") { store.isArchivePresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 18)

            TextField("Search archived tabs", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

            Divider()

            if entries.isEmpty {
                Text(store.state.archive.isEmpty ? "Tabs you close will show up here." : "No archived tabs match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    ArchiveRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.isArchivePresented = false
                            store.restoreArchived(entry.id)
                        }
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Picker("Archive unpinned tabs after", selection: archiveAfterBinding) {
                    ForEach(ArchiveView.archiveOptions, id: \.label) { option in
                        Text(option.label).tag(option.hours)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Clear Archive") { store.clearArchive() }
                    .disabled(store.state.archive.isEmpty)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 540, height: 540)
    }

    private var filteredEntries: [ArchivedTab] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return store.state.archive }
        return store.state.archive.filter { entry in
            FuzzyMatch.score(query: trimmed, candidate: entry.title) != nil
                || FuzzyMatch.score(query: trimmed, candidate: BrowsingHistory.displayURL(entry.url)) != nil
        }
    }

    private var archiveAfterBinding: Binding<Double?> {
        Binding(
            get: { store.state.settings.archiveAfterHours },
            set: { store.setArchiveAfterHours($0) }
        )
    }
}

private struct ArchiveRow: View {
    let entry: ArchivedTab

    var body: some View {
        HStack(spacing: 10) {
            FaviconView(url: entry.url)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(BrowsingHistory.displayURL(entry.url))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.archivedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}
