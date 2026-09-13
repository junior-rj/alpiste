import AppKit
import SwiftUI

/// Alpiste's preferences. A native grouped `Form`: the tool should disappear into the
/// task, so this reads like every other macOS settings pane rather than inventing its own
/// vocabulary. General holds the two opt-in toggles; Transcription is read-only status,
/// a quick way to see whether the keys and model are in place without opening the .env.
struct SettingsView: View {
    let state: AppState
    /// Loaded when the window appears, not on every body evaluation: the computed
    /// version read and parsed the file once per label, on the main thread.
    @State private var env: [String: String] = [:]

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
                        LabeledContent("Calendar access") {
                            Text("Blocked").foregroundStyle(.secondary)
                        }
                        Button("Open System Settings…") {
                            MeetingCalendar.openSystemSettings()
                        }
                    }
                }

                HStack {
                    Text("Meetings folder")
                    Spacer()
                    Text(state.outputDirectory.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Change…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = state.outputDirectory
                        if panel.runModal() == .OK, let url = panel.url { state.setOutputDirectory(url) }
                    }
                }
            }

            Section {
                LabeledContent("Language", value: language)
                LabeledContent("Groq API key") {
                    ConfigStatus(ready: isSet("GROQ_API_KEY"), readyLabel: "Set", missingLabel: "Not set")
                }
                LabeledContent("Gemini API key") {
                    ConfigStatus(ready: isSet("GEMINI_API_KEY"), readyLabel: "Set", missingLabel: "Not set")
                }
                LabeledContent("Local model") {
                    ConfigStatus(ready: modelInstalled, readyLabel: "Installed", missingLabel: "Missing")
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Set keys and language in \(Text("~/.alpiste/.env").monospaced()).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Reflect a change made outside the app (System Settings > Login Items) without a
        // relaunch, each time the window is shown.
        .task {
            state.refreshLaunchAtLoginStatus()
            env = Env.load()
        }
    }

    private var language: String { Notes.transcriptionLanguage(env) }

    /// Whether a key is present. The value itself is never read into the UI.
    private func isSet(_ key: String) -> Bool { !(env[key] ?? "").isEmpty }

    private var modelInstalled: Bool {
        FileManager.default.fileExists(atPath: Notes.modelURL.path)
    }
}

/// A configuration row's value: a status glyph plus the same state in words. The glyph
/// carries the color; the word carries the meaning for anyone who cannot see it, so color
/// is never the only cue. A filled green check reads "ready"; an empty neutral circle reads
/// "not configured" rather than "broken", because a single missing key is not an error when
/// the other provider or the API fallback still works.
private struct ConfigStatus: View {
    let ready: Bool
    let readyLabel: String
    let missingLabel: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .imageScale(.small)
                .foregroundStyle(ready ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(ready ? readyLabel : missingLabel)
                .foregroundStyle(.secondary)
        }
    }
}
