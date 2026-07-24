import SwiftUI

/// Live run detail for one workflow: per-step status, streaming output, and
/// stop / rerun controls. Reads the store's latest run for the workflow; before
/// the first run it previews the saved steps as pending.
struct WorkflowRunSheet: View {
    let workflowID: UUID

    @Environment(WorkflowStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Steps whose output disclosure is open. Running and failed steps are
    /// auto-expanded on phase changes; the user can still toggle any step.
    @State private var expanded: Set<UUID> = []

    private var workflow: Workflow? { store.workflow(workflowID) }
    private var run: WorkflowRunState? { store.runs[workflowID] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 680, height: 500)
        .onAppear { autoExpand() }
        .onChange(of: run?.steps.map(\.phase) ?? []) { _, _ in autoExpand() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "flowchart.fill").foregroundStyle(.tint)
            Text(workflow?.name ?? "Workflow").font(.headline)
            Spacer()
            if store.isRunning(workflowID) {
                Button { store.cancel(workflowID) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button { store.run(workflowID) } label: {
                    Label(run == nil ? "Run" : "Run Again", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(workflow == nil)
            }
            Button("Done") { dismiss() }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let run {
                        if let error = run.setupError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        ForEach(run.steps) { step in
                            stepView(step)
                        }
                    } else if let workflow {
                        // No run yet: preview the saved steps as pending.
                        ForEach(workflow.steps) { step in
                            HStack(spacing: 8) {
                                Image(systemName: "circle").foregroundStyle(.secondary)
                                Text(previewTitle(for: step))
                                    .font(.callout.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: outputFingerprint) { _, _ in
                if run?.isRunning == true {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Cheap change token for auto-scroll: total output length across steps.
    /// `utf8.count` is O(1) on native strings; `count` would grapheme-scan
    /// every step's output on each evaluation.
    private var outputFingerprint: Int {
        run?.steps.reduce(0) { $0 + $1.output.utf8.count } ?? 0
    }

    private func stepView(_ step: WorkflowRunStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { toggle(step.id) } label: {
                HStack(spacing: 8) {
                    phaseIcon(step.phase)
                    if step.phase == .running, let pid = step.pid {
                        Text(verbatim: "PID \(pid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(step.title)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if case .failed(let message) = step.phase {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    Image(systemName: expanded.contains(step.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(step.id), !step.output.isEmpty {
                Text(step.output)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    @ViewBuilder
    private func phaseIcon(_ phase: WorkflowRunStep.Phase) -> some View {
        switch phase {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let run {
                switch run.outcome {
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Running…").font(.callout).foregroundStyle(.secondary)
                case .succeeded:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Succeeded\(durationSuffix)").font(.callout).foregroundStyle(.secondary)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("Failed\(durationSuffix)").font(.callout).foregroundStyle(.secondary)
                case .cancelled:
                    Image(systemName: "stop.circle.fill").foregroundStyle(.orange)
                    Text("Stopped\(durationSuffix)").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Not run yet.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var durationSuffix: String {
        guard let duration = run?.duration else { return "" }
        if duration < 60 { return String(format: " in %.1fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return " in \(minutes)m \(seconds)s"
    }

    private func previewTitle(for step: WorkflowStep) -> String {
        switch step.action {
        case .shell(let command):
            return WorkflowStep.summary(of: command)
        case .runWorkflow(let id):
            return "Run “\(store.workflow(id)?.name ?? "missing workflow")”"
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Opens the disclosure of steps that just became running or failed, so the
    /// live output (or the failure's output) is visible without a click.
    private func autoExpand() {
        guard let run else { return }
        for step in run.steps {
            switch step.phase {
            case .running, .failed: expanded.insert(step.id)
            default: break
            }
        }
    }
}
