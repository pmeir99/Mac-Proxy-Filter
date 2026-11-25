import AppKit
import CoreImage
import FoundationModels
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision

enum Effect: String, CaseIterable, Identifiable {
    case blur = "Blur", pixelate = "Pixelate", solid = "Solid"
    var id: Self { self }
}

struct MaskEdit: Identifiable {
    let id: Int
    let mask: CIImage
    var effect: Effect = .blur
    var strength: Double = 24
    var color: Color = .black
}

struct Subjects {
    let width: Int
    let height: Int
    let labels: [UInt8]
    let masks: [Int: CIImage]

    static func detect(_ image: CGImage) throws -> Subjects {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first else {
            return Subjects(width: 0, height: 0, labels: [], masks: [:])
        }
        let buffer = result.instanceMask
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let labels = try readLabels(buffer, width: width, height: height)
        var masks = [Int: CIImage]()
        for id in result.allInstances {
            let mask = try result.generateScaledMaskForImage(forInstances: IndexSet(integer: id), from: handler)
            masks[id] = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        }
        return Subjects(width: width, height: height, labels: labels, masks: masks)
    }

    private static func readLabels(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [UInt8] {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw CocoaError(.fileReadUnknown)
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var labels = [UInt8]()
        labels.reserveCapacity(width * height)
        for row in 0..<height {
            labels.append(contentsOf: UnsafeBufferPointer(start: base + row * stride, count: width))
        }
        return labels
    }

    func hit(_ point: CGPoint, in size: CGSize) -> Int? {
        guard width > 0, height > 0, point.x >= 0, point.y >= 0,
              point.x < size.width, point.y < size.height else { return nil }
        let x = Int(point.x / size.width * CGFloat(width))
        let y = Int(point.y / size.height * CGFloat(height))
        let id = Int(labels[y * width + x])
        return masks[id] == nil ? nil : id
    }
}

@MainActor
final class Editor: ObservableObject {
    @Published var original: CGImage?
    @Published var preview: CGImage?
    @Published var edits: [MaskEdit] = []
    @Published var selection: Int?
    @Published var caption = ""
    @Published var status = ""
    @Published var message: String?
    @Published var updateURL: URL?
    private var subjects: Subjects?
    private var generation = UUID()
    private var captionTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private let context = CIContext()

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else {
            message = "This image could not be opened."
            return
        }
        captionTask?.cancel()
        detectionTask?.cancel()
        generation = UUID()
        let current = generation
        original = image
        preview = image
        subjects = nil
        edits = []
        selection = nil
        status = "Finding subjects…"
        caption = "Describing image…"

        detectionTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Subjects.detect(image) }
            }.value
            guard !Task.isCancelled, current == generation else { return }
            switch result {
            case .success(let detected):
                subjects = detected
                status = detected.masks.isEmpty ? "No foreground subjects found." : "Click a subject to add or edit its mask."
            case .failure:
                status = "Subject detection failed for this image."
            }
        }
        captionTask = Task {
            let model = SystemLanguageModel.default
            if #available(macOS 27.0, *), model.isAvailable {
                let input = scaled(CIImage(cgImage: image), maximum: 768)
                if let thumbnail = context.createCGImage(input, from: input.extent.integral) {
                    let session = LanguageModelSession(model: model)
                    let response = try? await session.respond {
                        "Describe the visible scene in one short sentence."
                        Attachment(thumbnail)
                    }
                    if let response {
                        guard !Task.isCancelled, current == generation else { return }
                        caption = response.content
                        return
                    }
                }
            }
            let tags = await Task.detached(priority: .utility) {
                let request = VNClassifyImageRequest()
                try? VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).filter { $0.confidence >= 0.15 }
                    .prefix(3).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            }.value
            guard !Task.isCancelled, current == generation else { return }
            caption = tags.isEmpty ? "No description available." : "Detected: " + tags.joined(separator: ", ")
        }
    }

    func click(_ point: CGPoint, size: CGSize) {
        guard let id = subjects?.hit(point, in: size), let mask = subjects?.masks[id] else {
            selection = nil
            return
        }
        selection = id
        if !edits.contains(where: { $0.id == id }) {
            edits.append(MaskEdit(id: id, mask: mask))
            refresh()
        }
    }

    func removeSelected() {
        edits.removeAll { $0.id == selection }
        selection = nil
        refresh()
    }

    private func scaled(_ image: CIImage, maximum: CGFloat) -> CIImage {
        let scale = min(1, maximum / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func render(maximum: CGFloat) -> CGImage? {
        guard let original else { return nil }
        let source = scaled(CIImage(cgImage: original), maximum: maximum)
        let scale = source.extent.width / CGFloat(original.width)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        var output = source
        for edit in edits {
            let filtered: CIImage
            switch edit.effect {
            case .blur:
                filtered = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: edit.strength * scale
                ])
            case .pixelate:
                filtered = source.applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: max(1, edit.strength * scale)
                ])
            case .solid:
                filtered = CIImage(color: CIColor(color: NSColor(edit.color)) ?? .black)
            }
            output = filtered.cropped(to: source.extent).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: output,
                kCIInputMaskImageKey: edit.mask.transformed(by: transform)
            ]).cropped(to: source.extent)
        }
        return context.createCGImage(output, from: source.extent.integral)
    }

    func refresh() { preview = render(maximum: 1600) }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Filtered.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = render(maximum: .greatestFiniteMagnitude),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            message = "Could not create the export."
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { message = "Could not write the PNG." }
    }

    func checkUpdates() async {
        struct Release: Decodable { let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool }
        updateURL = nil
        do {
            let endpoint = URL(string: "https://api.github.com/repos/pmeir99/Mac-Proxy-Filter/releases?per_page=100")!
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            let code = (response as? HTTPURLResponse)?.statusCode
            if code == 404 {
                message = "No stable release has been published yet."
                return
            }
            guard code == 200 else { throw URLError(.badServerResponse) }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            let prefix = "image-editor-v"
            let candidates = releases.filter {
                !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(prefix)
            }
            guard let release = candidates.max(by: {
                $0.tag_name.compare($1.tag_name, options: .numeric) == .orderedAscending
            }) else {
                message = "No stable image editor release has been published yet."
                return
            }
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
            let latest = String(release.tag_name.dropFirst(prefix.count))
            if latest.compare(installed, options: .numeric) == .orderedDescending {
                updateURL = release.html_url
                message = "Version \(latest) is available."
            } else {
                message = "You’re running the latest version."
            }
        } catch {
            message = "Could not check GitHub for updates."
        }
    }
}

struct EditorView: View {
    @ObservedObject var editor: Editor

    private func fittedSize(_ image: CGImage, in bounds: CGSize) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let ratio = Swift.min(bounds.width / width, bounds.height / height)
        return CGSize(width: width * ratio, height: height * ratio)
    }

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                if let image = editor.preview {
                    let size = fittedSize(image, in: geometry.size)
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { point in editor.click(point, size: size) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Image Filtration", systemImage: "photo")
                    } description: {
                        Text("Open or drop a photo to describe it and mask its subjects.")
                    } actions: {
                        Button("Open Image…", action: editor.open)
                    }
                }
            }
            .background(.black.opacity(0.08))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL else { return false }
                editor.load(url)
                return true
            }
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text("Description").font(.headline)
                Text(editor.caption.isEmpty ? "Open an image to begin." : editor.caption)
                    .textSelection(.enabled)
                if !editor.status.isEmpty {
                    Text(editor.status).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                ForEach(editor.edits) { edit in
                    Button("Subject \(edit.id)", systemImage: editor.selection == edit.id ? "checkmark.circle.fill" : "circle") {
                        editor.selection = edit.id
                    }.buttonStyle(.plain)
                }
                if let index = editor.edits.firstIndex(where: { $0.id == editor.selection }) {
                    Picker("Effect", selection: $editor.edits[index].effect) {
                        ForEach(Effect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if editor.edits[index].effect == .solid {
                        ColorPicker("Fill", selection: $editor.edits[index].color, supportsOpacity: false)
                    } else {
                        Slider(value: $editor.edits[index].strength, in: 4...100) { Text("Strength") }
                    }
                    Button("Remove Mask", role: .destructive, action: editor.removeSelected)
                }
                Spacer()
            }
            .padding(18)
            .frame(width: 260)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: editor.edits.map { "\($0.id)-\($0.effect)-\($0.strength)-\($0.color)" }) {
            editor.refresh()
        }
        .toolbar {
            Button("Open Image", systemImage: "folder", action: editor.open)
            Button("Export PNG", systemImage: "square.and.arrow.up", action: editor.export)
                .disabled(editor.original == nil)
        }
        .alert("Image Filtration", isPresented: Binding(
            get: { editor.message != nil }, set: { if !$0 { editor.message = nil } }
        )) {
            if let url = editor.updateURL {
                Button("Open Release") { NSWorkspace.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(editor.message ?? "") }
    }
}

@main
struct ImageFiltrationApp: App {
    @StateObject private var editor = Editor()

    var body: some Scene {
        Window("Image Filtration", id: "editor") {
            EditorView(editor: editor)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…", action: editor.open).keyboardShortcut("o")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await editor.checkUpdates() } }
            }
        }
    }
}
