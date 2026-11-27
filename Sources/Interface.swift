import SwiftUI
import UniformTypeIdentifiers
import ServiceManagement

struct Interface: View {
    @ObservedObject var model: Controller
    @AppStorage("maskStyle") var style = "Cover"
    @AppStorage("maskShape") var shape = "Silhouette"
    @AppStorage("maskStrength") var strength = 0.35
    @AppStorage("maskMargin") var margin = 0.0
    @AppStorage("maskColor") var hex = "222222"
    @AppStorage("backgroundMode") var backgroundMode = false
    @AppStorage("capture") var capture = false
    @AppStorage("captureImages") var captureImages = false
    @State private var exportImages = false
    @State private var decisions = Set<String>()
    @State private var hosts = Set<String>()
    @State private var methods = Set<String>()
    @State private var statuses = Set<String>()
    @State private var types = Set<String>()
    @State private var durations = ""
    @State private var selection: String?
    @State private var site = ""
    @State private var notice = ""
    @State private var busy = false
    var filters: ActivityFilters {
        ActivityFilters(site:site, durations:durations, decisions:decisions, hosts:hosts, methods:methods, statuses:statuses, types:types)
    }
    var visible: [Event] { filters.select(model.events) }
    func choices(_ title:String, _ options:[String], _ selected:Binding<Set<String>>) -> some View {
        Menu(selected.wrappedValue.isEmpty ? title : "\(title) (\(selected.wrappedValue.count))") {
            Button("All") { selected.wrappedValue.removeAll() }
            ForEach(Set(options).union(selected.wrappedValue).sorted(), id:\.self) { item in
                Toggle(item.isEmpty ? "Unspecified" : item, isOn:Binding(
                    get:{ selected.wrappedValue.contains(item) },
                    set:{ on in if on { selected.wrappedValue.insert(item) } else { selected.wrappedValue.remove(item) } }))
            }
        }
    }
    var body: some View {
        TabView {
            Form {
                Section("Protection") {
                    LabeledContent("Proxy",value:model.status)
                    if !model.activity.isEmpty { Text(model.activity).font(.callout).textSelection(.enabled) }
                    Button(model.active ? "Stop filtering" : "Enable filtering…") { if model.active { Task { _ = await model.disable() } } else { model.enableFromStopped() } }.buttonStyle(.borderedProminent).disabled(model.settingUp)
                    if !model.setupMessage.isEmpty { Text(model.setupMessage).foregroundStyle(.secondary) }
                }
                Section("Startup and background") {
                    Toggle("Start at login",isOn:Binding(get:{ model.loginStatus == .enabled || model.loginStatus == .requiresApproval },set:{ model.login($0) }))
                    if model.loginStatus == .requiresApproval {
                        Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Toggle("Keep filtering in the menu bar when I press ⌘Q",isOn:$backgroundMode)
                }
                Section("Websites") {
                    Toggle("Filter all public websites",isOn:$model.allSites)
                    if !model.allSites { Text("Included hosts"); TextEditor(text:$model.text).frame(height:50) }
                    Text("Connect directly to these hosts"); TextEditor(text:$model.exceptions).frame(height:45)
                }.disabled(model.active)
                DisclosureGroup("Network setup") {
                    Button("Check or repair setup…") { model.repairRouting() }.disabled(!model.active || model.settingUp)
                    Button("Restore previous routing…") { Task { _ = await model.disable() } }.disabled(model.settingUp)
                    Button("Show public certificate") { NSWorkspace.shared.activateFileViewerSelecting([model.certificate]) }
                }
            }.tabItem { Label("Overview",systemImage:"shield") }
            Form {
                Section("Appearance") {
                    Text("Changes apply to newly requested images. Reload a page to request its images again.").font(.callout)
                    Picker("Treatment",selection:$style) { Text("Gaussian blur").tag("Blur"); Text("Solid cover").tag("Cover") }.pickerStyle(.segmented)
                    if style == "Blur" { Slider(value:$strength,in:0.05...1) { Text("Blur strength · "+String(Int(strength*100))+"%") } }
                    else { ColorPicker("Cover color",selection:Binding(get:{
                        let n = Int(hex,radix:16) ?? 0
                        return Color(red:Double(n>>16)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255)
                    },set:{ color in
                        if let c = NSColor(color).usingColorSpace(.sRGB) { hex = String(format:"%02X%02X%02X",Int(c.redComponent*255),Int(c.greenComponent*255),Int(c.blueComponent*255)) }
                    }),supportsOpacity:false) }
                }
                Section("Coverage") {
                    Picker("Shape",selection:$shape) { Text("Follow people").tag("Silhouette"); Text("Enclosing rectangle").tag("Rectangle") }
                    Slider(value:$margin,in:0...0.2,step:0.01) { Text("Extra margin · "+String(Int((margin*100).rounded()))+"%") }
                    Text("Each rectangle covers a confirmed region. Margin is relative to the shorter image dimension.").foregroundStyle(.secondary)
                }
            }.onChange(of:[style,shape,String(strength),String(margin),hex]) { _,_ in if model.active { model.saveMaskSettings() } }.tabItem { Label("Mask",systemImage:"person.crop.rectangle") }
            VStack(alignment:.leading,spacing:12) {
                Toggle("Capture request activity",isOn:$capture).disabled(model.active)
                Toggle("Retain before and after images",isOn:$captureImages).disabled(model.active || !capture)
                Text("Choose capture options before starting. Records stay in memory for up to five minutes. Retained images can contain original unmasked content.").font(.caption)
                Text(model.activity).font(.callout)
                HStack {
                    TextField("Search recorded fields · commas mean OR",text:$site)
                    TextField("Total ms · e.g. 0-100, 500+",text:$durations).frame(maxWidth:220)
                }
                if filters.ranges == nil { Text("Enter milliseconds as 100, 100-250, or 500+.").foregroundStyle(.red) }
                HStack {
                    choices("Decision",model.events.map(\.outcome),$decisions)
                    choices("Host",model.events.flatMap { [$0.host,$0.site] }.filter { !$0.isEmpty },$hosts)
                    choices("Method",model.events.map(\.method),$methods)
                    choices("Status",model.events.map { String($0.status) },$statuses)
                    choices("Type",model.events.map(\.mime),$types)
                    Button("Reset") {
                        site = ""; durations = ""; decisions = []; hosts = []; statuses = []; methods = []; types = []
                    }
                }
                Text("\(visible.count) matching records").font(.caption)
                Table(visible, selection:$selection) {
                    TableColumn("Image host",value:\.host)
                    TableColumn("Decision",value:\.verdict)
                    TableColumn("Total") { Text("\($0.elapsedMS) ms") }
                }
                if let event = visible.first(where: { $0.id == selection }) {
                    ScrollView {
                        VStack(alignment:.leading,spacing:4) {
                            Text(Date(timeIntervalSince1970:event.time).formatted() + " · " + event.method + " · " + event.mime)
                            if let path = event.path { Text(path).lineLimit(2) }
                            Text("Referring host " + (event.site.isEmpty ? "unavailable" : event.site))
                            Text("Response \(event.status) · input \(event.beforeBytes) bytes · output \(event.afterBytes) bytes")
                            if let origin = event.origin {
                                Text("Origin HTTP \(origin.status) · \(origin.encoding) · declared bytes " + (origin.declaredLength.isEmpty ? "unknown" : origin.declaredLength))
                            }
                            if let failure = event.failure { Text(failure).foregroundStyle(.red) }
                            if let message = event.recognition { Text(message) }
                            if let hit = event.cacheHit { Text(hit ? "Cached decision" : "Fresh scan") }
                            ForEach(event.processing.keys.sorted(),id:\.self) { stage in
                                Text(stage.replacingOccurrences(of:"MS",with:"") + " · " + String(event.processing[stage] ?? 0) + " ms")
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                    }.frame(maxHeight:130)
                }
                HStack {
                    Toggle("Include retained images in ZIP",isOn:$exportImages).disabled(!captureImages)
                    Button("Export selected request…") {
                        if let selection { export(ids:[selection]) }
                    }.disabled(busy || !visible.contains { $0.id == selection })
                    Button("Export filtered activity…") { export(ids:visible.map(\.id)) }.disabled(visible.isEmpty || busy)
                }
                Text(notice).font(.caption)
            }.padding().tabItem { Label("Activity",systemImage:"waveform.path.ecg") }
            Form { Section("Mac Proxy Filter") {
                LabeledContent("Installed release",value:Bundle.main.object(forInfoDictionaryKey:"FilterRelease") as? String ?? "Development")
                Button("Check for Updates") { update() }.disabled(busy)
                Text(notice).foregroundStyle(.secondary)
            } }.tabItem { Label("Updates",systemImage:"arrow.down.circle") }
        }.formStyle(.grouped).frame(minWidth:660,minHeight:530)
    }
    func export(ids:[String]) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = ids.count == 1 ? "Filter request.zip" : "Filter diagnostics.zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do { let bytes = try await model.diagnostics("export",images:captureImages && exportImages,ids:ids); try bytes.write(to:url,options:.atomic); notice = "Saved "+url.lastPathComponent }
            catch { notice = error.localizedDescription }
        }
    }
    func update() {
        busy = true; notice = "Checking for updates…"
        Task {
            defer { busy = false }
            do {
                guard let (tag,asset) = try await Updates.check() else { notice = "You’re up to date."; return }
                let alert = NSAlert(); alert.messageText = "Install "+tag+"?"; alert.informativeText = "Filtering will pause and the app will reopen."
                alert.addButton(withTitle:"Download and install"); alert.addButton(withTitle:"Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {notice = ""; return}
                notice = "Downloading and verifying…"
                let fresh = try await Updates.prepare(asset,tag:tag)
                let installed = Bundle.main.bundleURL
                let p = Process(); p.executableURL = URL(fileURLWithPath:"/bin/bash")
                p.arguments = [Bundle.main.url(forResource:"install-update",withExtension:"sh")!.path,fresh.path,installed.path,String(ProcessInfo.processInfo.processIdentifier)]
                // Stage on the target volume before ending the running application.
                let staging = installed.deletingLastPathComponent().appendingPathComponent(".filter-"+UUID().uuidString)
                try FileManager.default.copyItem(at:fresh,to:staging)
                p.arguments![1] = staging.path
                let resume = model.active
                if model.settingUp { try? FileManager.default.removeItem(at:staging); notice = "Finish network setup before updating."; return }
                if resume {
                    guard await model.disable(manual:false) else {
                        try? FileManager.default.removeItem(at:staging)
                        notice = model.setupMessage
                        return
                    }
                }
                do { try p.run() } catch {
                    try? FileManager.default.removeItem(at:staging)
                    if resume { model.enableFromStopped() }
                    throw error
                }
                UserDefaults.standard.set(resume,forKey:"resumeAfterUpdate")
                NSApp.terminate(nil)
            } catch { notice = error.localizedDescription }
        }
    }
}
