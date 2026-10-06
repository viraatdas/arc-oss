import AppKit

@main
enum RadianApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared

        if let snapshot = Snapshot.options(from: CommandLine.arguments) {
            // No Dock icon, no menu bar, no window on screen: render and exit.
            application.setActivationPolicy(.prohibited)
            Snapshot.run(snapshot)
            application.run()
            return
        }

        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        // `run` never returns, which keeps `delegate` alive for the life of the process.
        application.run()
    }
}
