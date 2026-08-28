import SwiftUI

struct SessionView: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Traducción activa").font(.title.bold())
                    Text("\(SupportedLanguage.named(model.settings.localLanguage)) ↔ \(SupportedLanguage.named(model.settings.remoteLanguage))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let started = model.sessionStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(duration(from: started, to: context.date))
                            .monospacedDigit()
                    }
                }
                Button("Detener", role: .destructive) {
                    Task { await model.stop() }
                }
                .disabled(model.isBusy)
            }

            HStack(alignment: .top, spacing: 16) {
                PipelineCard(
                    pipeline: model.localToRemote,
                    sourceName: "Tú",
                    targetName: "Persona remota",
                    bypassLabel: "Mantén para enviar original"
                )
                PipelineCard(
                    pipeline: model.remoteToLocal,
                    sourceName: "Persona remota",
                    targetName: "Tú",
                    bypassLabel: "Mantén para escuchar original"
                )
            }
            Spacer(minLength: 0)
        }
        .padding(26)
    }

    private func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

private struct PipelineCard: View {
    @ObservedObject var pipeline: TranslationPipeline
    let sourceName: String
    let targetName: String
    let bypassLabel: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(pipeline.direction.title).font(.headline)
                    Spacer()
                    Circle()
                        .fill(stateColor)
                        .frame(width: 9, height: 9)
                    Text(pipeline.state.label).font(.caption)
                }

                ProgressView(value: Double(min(1, pipeline.inputLevel * 4)))
                    .progressViewStyle(.linear)

                transcript(title: "Original · \(sourceName)", text: pipeline.inputTranscript)
                transcript(title: "Traducción · \(targetName)", text: pipeline.outputTranscript)

                Text(bypassLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(pipeline.bypassEnabled ? Color.red : Color.secondary.opacity(0.14))
                    .foregroundStyle(pipeline.bypassEnabled ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in pipeline.setBypass(true) }
                            .onEnded { _ in pipeline.setBypass(false) }
                    )

                if let error = pipeline.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }

    private func transcript(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "Esperando voz…" : text)
                    .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 110)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var stateColor: Color {
        switch pipeline.state {
        case .active: return .green
        case .connecting, .reconnecting, .validating, .stopping: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }
}
