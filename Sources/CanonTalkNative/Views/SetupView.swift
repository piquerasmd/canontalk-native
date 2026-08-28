import SwiftUI

struct SetupView: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var devices: AudioDeviceService

    init(model: AppViewModel) {
        self.model = model
        settings = model.settings
        devices = model.devices
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                credentials
                languages
                routing
                callInstructions
                startArea
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CanonTalk Native")
                .font(.largeTitle.bold())
            Text("Traducción simultánea en ambos sentidos, con una salida distinta para cada oyente.")
                .foregroundStyle(.secondary)
        }
    }

    private var credentials: some View {
        GroupBox("OpenAI") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("sk-…", text: $model.apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Guardar en Keychain") { model.saveAPIKey() }
                    if model.hasStoredAPIKey {
                        Label("Guardada localmente", systemImage: "checkmark.shield")
                            .foregroundStyle(.green)
                        Button("Eliminar", role: .destructive) { model.deleteAPIKey() }
                    }
                }
                Text("El audio se envía a OpenAI durante la sesión. La aplicación no guarda audio ni transcripciones.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var languages: some View {
        GroupBox("Idiomas") {
            HStack(spacing: 16) {
                languagePicker("Yo escucho", selection: $settings.localLanguage)
                Button(action: { settings.swapLanguages() }) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .help("Intercambiar idiomas")
                languagePicker("La otra persona escucha", selection: $settings.remoteLanguage)
            }
            .padding(8)
        }
    }

    private func languagePicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(SupportedLanguage.all) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var routing: some View {
        GroupBox("Dispositivos de audio") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                deviceRow(
                    "Tu micrófono",
                    selection: $settings.microphoneUID,
                    options: devices.inputDevices.filter { !$0.isBlackHole }
                )
                deviceRow(
                    "Tus auriculares",
                    selection: $settings.headphonesUID,
                    options: devices.outputDevices.filter { !$0.isBlackHole }
                )
                deviceRow(
                    "Audio de la llamada",
                    selection: $settings.remoteCaptureUID,
                    options: devices.inputDevices.filter(\.isBlackHole)
                )
                deviceRow(
                    "Micrófono traducido",
                    selection: $settings.translatedMicUID,
                    options: devices.outputDevices.filter(\.isBlackHole)
                )
            }
            .padding(8)
        }
    }

    private func deviceRow(
        _ label: String,
        selection: Binding<String>,
        options: [AudioDevice]
    ) -> some View {
        GridRow {
            Text(label).frame(width: 180, alignment: .leading)
            Picker(label, selection: selection) {
                Text("Seleccionar…").tag("")
                ForEach(options) { device in
                    Text(device.displayName).tag(device.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private var callInstructions: some View {
        GroupBox("Configuración de Zoom o Google Meet") {
            VStack(alignment: .leading, spacing: 8) {
                Label("Micrófono de la llamada: BlackHole 16ch", systemImage: "1.circle.fill")
                Label("Altavoz de la llamada: BlackHole 2ch", systemImage: "2.circle.fill")
                Label("Usa auriculares; no selecciones altavoces físicos.", systemImage: "headphones")
                    .foregroundStyle(.orange)
                Text("No uses el mismo BlackHole en ambos sentidos. La aplicación bloqueará esa configuración.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var startArea: some View {
        HStack {
            if let error = devices.lastError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("\(devices.devices.count) dispositivos detectados")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Actualizar dispositivos") { devices.refresh() }
            Button {
                Task { await model.start() }
            } label: {
                if model.isBusy { ProgressView().controlSize(.small) } else { Text("Iniciar traducción") }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isBusy)
        }
    }
}
