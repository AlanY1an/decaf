import SwiftUI

@main
struct UpdaterSmokeApp: App {
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    var body: some Scene {
        WindowGroup("Decaf updater test") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Try an update").font(.title2.weight(.semibold))
                    Text("Installed · test build " + build).foregroundStyle(.secondary)
                }
                CheckForUpdatesButton()
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved preference: " + (UserDefaults.standard.string(forKey: "smokePreference") ?? "missing"))
                    Text("Updates this test app only.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 400, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear {
                    if build == "41", UserDefaults.standard.string(forKey: "smokePreference") == nil {
                        UserDefaults.standard.set("kept-through-update", forKey: "smokePreference")
                    }
                }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
