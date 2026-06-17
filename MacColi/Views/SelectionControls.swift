import SwiftUI

/// Leading checkbox shown on each row while a resource panel is in "Select" mode.
struct SelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .imageScale(.large)
    }
}

/// Bottom bar shown in a resource panel's "Select" mode: a Select-All/Deselect-All
/// toggle and the selected count on the left, panel-specific bulk-action buttons
/// on the right. The actions are the caller's (each panel offers different
/// operations) and are disabled automatically when nothing is selected.
struct SelectionBar<Actions: View>: View {
    let count: Int
    let total: Int
    let onSelectAll: () -> Void
    let onClear: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Button(count == total && total > 0 ? "Deselect All" : "Select All") {
                count == total && total > 0 ? onClear() : onSelectAll()
            }
            .disabled(total == 0)

            Text("\(count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) { actions }
                .disabled(count == 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
