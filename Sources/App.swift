import SwiftUI
import AppKit
import SystemConfiguration

@MainActor
final class Controller: ObservableObject {
    @Published var text = UserDefaults.standard.string(forKey: "domains") ?? "" {
        didSet { UserDefaults.standard.set(text, forKey: "domains") }
    }
    @Published var allSites = UserDefaults.standard.bool(forKey: "allSites") {
        didSet { UserDefaults.standard.set(allSites, forKey: "allSites") }
    }
    @Published var exceptions = UserDefaults.standard.string(forKey: "exceptions") ?? "" {
        didSet { UserDefaults.standard.set(exceptions, forKey: "exceptions") }
    }
    @Published var activity = ""
    private var setupAfterStart = false
    @Published var status = "Stopped"
    @Published var active = false
    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Mac Proxy Filter", isDirectory: true)
    @Published var setupMessage = ""
    @Published var settingUp = false

    func setup(enable: Bool) {
        guard !settingUp else { return }
        settingUp = true
        let hosts = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let bypass = Set(exceptions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let probe = (allSites ? ["example.com","example.org"] : hosts).first { !bypass.contains($0) }
        setupMessage = enable ? "Checking HTTPS and requesting any required approvals…" : "Restoring network routing…"
        let cert = certificate
        Task {
            do {
                setupMessage = try await Task.detached {
                    if enable {
                        guard let probe else { throw NetworkSetup.failure("Select a destination outside the bypass list.") }
                        do { try NetworkSetup.checkHTTPS(host: probe) }
                        catch {
                            try NetworkSetup.trust(cert)
                            try NetworkSetup.checkHTTPS(host: probe)
                        }
                    }
                    return try NetworkSetup.apply(enable: enable)
                }.value
            } catch { setupMessage = error.localizedDescription }
            settingUp = false
        }
    }
    var process: Process?
    var ready: URL?
    var certificate: URL { directory.appendingPathComponent("mitmproxy-ca-cert.pem") }

    func observe(_ child: Process) async {
        let url = URL(string: "http://127.0.0.1:17861/status")!
        while process === child {
            let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
            let routed = proxies[NetworkSetup.enabled] as? Int == 1 && proxies[NetworkSetup.address] as? String == NetworkSetup.url
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let counts = try JSONDecoder().decode([String:Int].self, from: data)
                guard process === child else { return }
                let n = counts["requests", default: 0]
                let label = routed ? "Enabled on current network" : "Running • current network routing unconfirmed"
                activity = label + " · " + String(n) + " requests · " + String(counts["scanned", default: 0]) + " images scanned · " + String(counts["masked", default: 0]) + " masked · " + String(counts["errors", default: 0]) + " scan errors"
            } catch { if process === child { activity = "Waiting for local proxy diagnostics…" } }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    func start() {
        guard process == nil else { return }
        let hosts = text.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        let excluded = exceptions.components(separatedBy: .newlines).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty }
        guard (allSites || !hosts.isEmpty), ((allSites ? [] : hosts) + excluded).allSatisfy({ host in
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
            child.arguments = ["--quiet","--mode","regular","--listen-host","127.0.0.1","--listen-port","17862",
                               "--set","confdir="+directory.path,"--set","flow_detail=0","--set","termlog_verbosity=error",
                               "--set","connection_strategy=lazy","--set","onboarding=false","--set","ssl_insecure=false",
                               "-s",resources.appendingPathComponent("filter.py").path]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment.removeValue(forKey: "PYTHONHOME")
            environment.removeValue(forKey: "PYTHONPATH")
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["FILTER_DOMAINS"] = String(decoding:try JSONEncoder().encode(allSites ? [] : hosts),as:UTF8.self)
            environment["FILTER_ALL"] = allSites ? "1" : "0"
            environment["FILTER_EXCLUDED"] = String(decoding:try JSONEncoder().encode(excluded),as:UTF8.self)
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
                        if self.setupAfterStart { self.setupAfterStart = false; self.setup(enable: true) }
                        await self.observe(child)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                if self.process === child { self.stop(); self.status = "Proxy startup timed out." }
            }
        } catch { status = error.localizedDescription }
    }

    func enableFromStopped() { setupAfterStart = true; start() }

    func stop() {
        activity = ""
        setupAfterStart = false
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
                    Toggle("Filter all public websites", isOn: $model.allSites).disabled(model.active)
                    if !model.allSites {
                        Text("Filter these destination hosts, one per line")
                        TextEditor(text: $model.text).frame(minHeight:60).disabled(model.active)
                    }
                    Text("Always connect directly to these hosts, one per line")
                    TextEditor(text: $model.exceptions).frame(minHeight:45).disabled(model.active)
                }
                Section("Local proxy") {
                    Text(model.status)
                    if model.active { Text(model.activity).textSelection(.enabled) }
                    Button(model.active ? "Stop" : "Enable filtering…") { if model.active { model.stop() } else { model.enableFromStopped() } }.disabled(model.settingUp)
                    Button("Check or repair setup…") { model.setup(enable: true) }
                        .disabled(model.settingUp || model.status != "Listening on this Mac")
                    Text("Approves SSL trust for this account and configures existing network services. Keep the app running while routing is enabled.").font(.caption)
                    Button("Restore previous network routing…") { model.setup(enable: false) }
                        .disabled(model.settingUp)
                    if !model.setupMessage.isEmpty { Text(model.setupMessage).textSelection(.enabled) }
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
