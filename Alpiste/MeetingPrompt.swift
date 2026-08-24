import AppKit
import SwiftUI

/// The "want me to record this?" panel.
///
/// A floating panel rather than a notification or an alert, for reasons that are specific
/// rather than aesthetic. A notification is hidden by Focus, which is exactly what is on
/// during a meeting. A modal alert steals the keyboard at the moment you are typing your
/// name into a waiting room. A non-activating panel is visible either way and interrupts
/// nothing: the click that dismisses it never pulls Alpiste in front of the call.
@MainActor
enum MeetingPrompt {
    /// Long enough to notice after settling into a call, short enough that a stale panel
    /// is not still sitting there an hour later. Timing out counts as "Not now".
    static let timeout: TimeInterval = 90

    private static var panel: NSPanel?
    private static var timeoutTask: Task<Void, Never>?

    /// Replaces any panel already on screen, so a second detection cannot stack two.
    static func show(subtitle: String?,
                     onAccept: @escaping @MainActor () -> Void,
                     onDecline: @escaping @MainActor () -> Void) {
        dismiss()

        let content = PromptView(
            subtitle: subtitle,
            accept: { dismiss(); onAccept() },
            decline: { dismiss(); onDecline() })

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 0),
                            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        // Follows you across desktops and sits above a full-screen call, which is where
        // the meeting actually is.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Nothing here should count as the app's last window or show up in the switcher.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        panel.layoutIfNeeded()

        position(panel)
        // orderFrontRegardless, not makeKeyAndOrderFront: the panel must appear without
        // Alpiste taking the foreground away from the meeting.
        panel.orderFrontRegardless()
        Self.panel = panel

        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, Self.panel != nil else { return }
            Log.write("meeting prompt: timed out, treating it as Not now")
            dismiss()
            onDecline()
        }
    }

    static func dismiss() {
        timeoutTask?.cancel()
        timeoutTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    static var isShowing: Bool { panel != nil }

    /// Top-right, under the menu bar, near the Alpiste icon the panel is talking about.
    private static func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 16,
                                     y: area.maxY - size.height - 8))
    }
}

private struct PromptView: View {
    let subtitle: String?
    let accept: @MainActor () -> Void
    let decline: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("Meeting detected")
                    .font(.headline)
            }

            // The calendar title when there is one, so it is obvious *which* call this is
            // about before agreeing to record it.
            Text(subtitle ?? "A call is using your microphone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Not now", action: decline)
                    .keyboardShortcut(.cancelAction)
                Button("Record", action: accept)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
