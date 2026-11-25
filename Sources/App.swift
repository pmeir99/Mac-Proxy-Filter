import SwiftUI
import AppKit

@MainActor
final class Controller: ObservableObject {
    @Published var text = UserDefaults.standard.string(forKey: "domains") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "domains") }
    }
    @Published var status = "Stopped"
    @Published var active = false
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mac Proxy Filter", isDirectory: true)
    var process: Process?
    var ready: URL?
    var certificate: URL { directory.appendingPathComponent("mitmproxy-ca-cert.pem") }

    func start() {
        guard process == nil else { return }
        let hosts = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard !hosts.isEmpty, hosts.allSatisfy({ host in
            let parts = host.components(separatedBy: ".")
            return host.utf8.count <= 253 && parts.count >= 2 && parts.last?.allSatisfy(\.isNumber) == false &&
                parts.allSatisfy { $0.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options:.regularExpression) != nil }
        }) else { status = "Enter one exact hostname per line."; return }
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/mitmproxy.app/Contents/MacOS/mitmdump")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            status = "The app is incomplete. Replace it with a fresh copy from Releases."
            return
        }
        let child = Process()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions:0o700])
            let token = directory.appendingPathComponent(UUID().uuidString)
            ready = token
            let resources = Bundle.main.resourceURL!
            child.executableURL = executable
            let names = Set(hosts).sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let scope = "(?i)^(?:" + names + #")\.?:[0-9]+$"#
            child.arguments = ["--quiet","--allow-hosts",scope,"--mode","regular","--listen-host","127.0.0.1","--listen-port","17862",
                               "--set","confdir="+directory.path,"--set","flow_detail=0","--set","termlog_verbosity=error",
                               "--set","connection_strategy=lazy","--set","onboarding=false","--set","ssl_insecure=false",
                               "-s",resources.appendingPathComponent("filter.py").path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment.removeValue(forKey: "PYTHONHOME")
            environment.removeValue(forKey: "PYTHONPATH")
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["FILTER_DOMAINS"] = String(decoding:try JSONEncoder().encode(hosts),as:UTF8.self)
            environment["FILTER_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            environment["FILTER_READY"] = token.path
            environment["FILTER_WORKER"] = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MaskWorker").path
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.process === finished else { return }
                    self.active = false
                    self.process = nil
                    self.status = "Stopped. Check that ports 17861 and 17862 are available."
                    try? FileManager.default.removeItem(at: token)
                }
            }
            try child.run()
            process = child
            active = true
            status = "Starting…"
            Task {
                for _ in 0..<300 {
                    guard self.process === child else { return }
                    if FileManager.default.fileExists(atPath: token.path) {
                        self.status = "Listening on this Mac"
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if self.process === child { self.stop(); self.status = "Proxy startup timed out." }
            }
        } catch { status = error.localizedDescription }
    }

    func stop() {
        if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
        if let ready { try? FileManager.default.removeItem(at: ready) }
        process = nil
        active = false
        status = "Stopped"
    }
}

@main
struct FilterApp: App {
    @StateObject private var model = Controller()
    var body: some Scene {
        WindowGroup("Mac Proxy Filter") {
            Form {
                Section("Domains") {
                    Text("Enter one exact destination per line, including image CDN hosts. A shared CDN is filtered wherever it is used.")
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.text).font(.system(.body, design:.monospaced))
                        .frame(minHeight:95).disabled(model.active)
                }
                Section("Local proxy") {
                    Text(model.status)
                    Button(model.active ? "Stop" : "Start") { if model.active { model.stop() } else { model.start() } }
                    Text("Automatic proxy configuration URL").font(.caption)
                    Text("http://127.0.0.1:17861/proxy.pac").textSelection(.enabled)
                    Button("Show public certificate in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.certificate])
                    }.disabled(!model.active || !FileManager.default.fileExists(atPath:model.certificate.path))
                }
            }.formStyle(.grouped).frame(minWidth:480,minHeight:420)
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
    }
}
