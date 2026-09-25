import Foundation

/// User-facing copy for one destructive-action confirmation dialog.
struct ConfirmationCopy {
    var title: String
    var message: String
    var actionLabel: String
}

/// The shared wording for destructive-action confirmations, so the panels and
/// the ⇧⌘P command palette present identical dialogs and can't drift apart.
/// Deliberately pure values/functions: everything the copy varies on (a
/// container's running state, whether colima.yaml has custom provisioning) is
/// passed in, keeping this testable without AppState or the main actor.
enum Confirmations {
    /// Single-container removal. Inside a custom list, ContainersView overrides
    /// title and action label with its list-aware variants ("Delete …") but
    /// keeps this message, so the force-remove warning stays in one place.
    static func removeContainer(_ container: Container) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "Remove \(container.displayName)?",
            message: container.isRunning
                ? "This container is running and will be force-removed. This cannot be undone."
                : "This cannot be undone.",
            actionLabel: "Remove")
    }

    /// `docker system prune` with the 24-hour age filter (see AppState.pruneSystem).
    static let prune = ConfirmationCopy(
        title: "Remove unused data older than 24 hours?",
        message: "Deletes stopped containers, dangling images, unused networks, and "
            + "build cache not used in the last 24 hours. Volumes are kept. "
            + "This cannot be undone.",
        actionLabel: "Clean Up")

    /// `colima delete` — the whole VM and everything inside it.
    static func deleteVM(profile: String, hasCustomProvisioning: Bool) -> ConfirmationCopy {
        ConfirmationCopy(
            title: "Delete the “\(profile)” Colima VM?",
            message: hasCustomProvisioning
                ? "This permanently removes the VM and everything inside it, including custom provisioning in colima.yaml. This cannot be undone."
                : "This permanently removes the VM and everything inside it. This cannot be undone.",
            actionLabel: "Delete")
    }
}
