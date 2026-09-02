import SwiftUI

/// Alpiste's preferences. A native grouped `Form`: the tool should disappear into the
/// task, so this reads like every other macOS settings pane rather than inventing its own
/// vocabulary. General holds the two opt-in toggles; Transcription is read-only status,
/// a quick way to see whether the keys and model are in place without opening the .env.
struct SettingsView: View {
    let state: AppState

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { state.launchAtLoginEnabled },
                    set: { state.setLaunchAtLogin($0) }))

                Toggle("Auto-start on meetings", isOn: Binding(
                    get: { state.autoStartOnMeetings },
                    set: { state.setAutoStartOnMeetings($0) }))

                // Recording still works without the calendar, so this is a note, not an
                // alarm. The two failures need opposite actions: one the app can still
                // resolve with a dialog, one only System Settings can.
                if state.autoStartOnMeetings {
                    switch state.meetingCalendarStatus {
                    case .available:
                        EmptyView()
                    case .notAsked:
                        Button("Allow Calendar Access…") { state.requestCalendarAccess() }
                    case .blocked:
                        Button("Calendar Access Blocked — Open Settings") {
                            MeetingCalendar.openSystemSettings()
                        }
                    }
                }
            }

            Section {
                LabeledContent("Language", value: language)
                LabeledContent("Groq API key", value: status(for: "GROQ_API_KEY"))
                LabeledContent("Gemini API key", value: status(for: "GEMINI_API_KEY"))
                LabeledContent("Local model", value: modelStatus)
            } header: {
                Text("Transcription")
            } footer: {
                Text("Set keys and language in ~/.alpiste/.env")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Reflect a change made outside the app (System Settings > Login Items) without a
        // relaunch, each time the window is shown.
        .task { state.refreshLaunchAtLoginStatus() }
    }

    // Read fresh each time the pane is shown; the .env is tiny and settings open rarely.
    private var env: [String: String] { Env.load() }

    private var language: String { Notes.transcriptionLanguage(env) }

    /// "Set" / "Not set" — never the value itself.
    private func status(for key: String) -> String {
        (env[key] ?? "").isEmpty ? "Not set" : "Set"
    }

    private var modelStatus: String {
        FileManager.default.fileExists(atPath: Notes.modelURL.path) ? "Installed" : "Missing"
    }
}
