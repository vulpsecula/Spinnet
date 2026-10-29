import SwiftUI
import SpinnetCore

/// The whole validated disclosure stays in the Host; only one bounded page
/// becomes SwiftUI rows. Selection cannot change the mutation plan.
struct HostConfirmationDetailsContent: View {
    let details: HostConfirmationDetails
    let height: CGFloat
    @State private var showsVerification = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details.localizedTitle).font(.headline)
            List {
                Text(details.localizedSummary).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .listRowSeparator(.hidden)
                HostConfirmationPagedRows(rows: details.actionRows)
                if !details.verificationRows.isEmpty {
                    DisclosureGroup(isExpanded: $showsVerification) {
                        HostConfirmationPagedRows(rows: details.verificationRows)
                    } label: {
                        Text(localized("Verification Details (\(details.verificationRows.count))"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: max(60, height - 30))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(details.localizedTitle)
    }
}

/// Each group pages independently, including evidence when expanded. The
/// complete validated rows remain available without flooding the view tree.
private struct HostConfirmationPagedRows: View {
    let rows: [HostConfirmationDetails.Row]
    @State private var page = 0
    private var pageCount: Int { max(1, (rows.count + HostConfirmationDetails.pageSize - 1) / HostConfirmationDetails.pageSize) }
    private var visibleRows: ArraySlice<HostConfirmationDetails.Row> {
        let offset = page * HostConfirmationDetails.pageSize
        return rows[offset..<min(rows.count, offset + HostConfirmationDetails.pageSize)]
    }
    var body: some View {
        ForEach(visibleRows) { row in
            HostConfirmationDetailRow(row: row)
                .padding(.vertical, 5)
        }
        if pageCount > 1 {
            HStack {
                Button(localized("Previous")) { page -= 1 }.disabled(page == 0)
                Picker(localized("Page"), selection: $page) {
                    ForEach(0..<pageCount, id: \.self) { number in
                        Text(localized("\(number + 1) of \(pageCount)")).tag(number)
                    }
                }.frame(maxWidth: 170)
                Button(localized("Next")) { page += 1 }.disabled(page + 1 == pageCount)
                Spacer()
                Text(localized("\(rows.count) entries")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
private struct HostConfirmationDetailRow: View {
    let row: HostConfirmationDetails.Row
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.localizedTitle).font(.callout).fontWeight(.medium)
            Text(row.localizedDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
