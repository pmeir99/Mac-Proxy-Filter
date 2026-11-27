import Foundation
import CoreImage
import CoreML
import ImageIO
import Vision
import UniformTypeIdentifiers

enum ScanFailure: Error { case unsupported }
let context = CIContext()
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let input = FileHandle.standardInput
let output = FileHandle.standardOutput

func read(_ count: Int) -> Data? {
    var data = Data()
    while data.count < count {
        let part = input.readData(ofLength: count - data.count)
        if part.isEmpty { return nil }
        data.append(part)
    }
    return data
}

enum SemanticPeople {
    private static let model: VNCoreMLModel? = {
        let resources = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let compiled = try? MLModel(contentsOf: resources.appendingPathComponent("DeepLabV3FP16.mlmodelc"),
                                          configuration: configuration) else { return nil }
        return try? VNCoreMLModel(for: compiled)
    }()

    static func mask(_ image: CGImage) throws -> CVPixelBuffer {
        guard let model else { throw ScanFailure.unsupported }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let result = request.results?.first as? VNCoreMLFeatureValueObservation,
              let labels = result.featureValue.multiArrayValue,
              labels.shape.count >= 2, labels.shape.dropLast(2).allSatisfy({ $0.intValue == 1 }) else {
            throw ScanFailure.unsupported
        }
        let dims = labels.shape.suffix(2).map(\.intValue)
        let steps = labels.strides.suffix(2).map(\.intValue)
        let h = dims[0], w = dims[1]
        guard w>0, h>0, w<=1024, h<=1024 else { throw ScanFailure.unsupported }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_OneComponent8,nil,&buffer)==kCVReturnSuccess,
              let buffer else { throw ScanFailure.unsupported }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw ScanFailure.unsupported }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            throw ScanFailure.unsupported
        }
        let output = destination.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func copyLabels<T: BinaryInteger>(_ input: UnsafePointer<T>) {
            for y in 0..<h {
                for x in 0..<w {
                    let person = input[y*steps[0]+x*steps[1]] == 15
                    output[y*stride+x] = person ? 255 : 0
                }
            }
        }
        if labels.dataType == .int32 {
            copyLabels(UnsafePointer(labels.dataPointer.assumingMemoryBound(to: Int32.self)))
        } else {
            for y in 0..<h {
                for x in 0..<w {
                    let person = labels[y*steps[0]+x*steps[1]].intValue == 15
                    output[y*stride+x] = person ? 255 : 0
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

final class ScanTimings {
    private var started = ProcessInfo.processInfo.systemUptime
    private(set) var phase = "decode"
    private(set) var values = [String: Int]()
    func next(_ name: String) {
        let now = ProcessInfo.processInfo.systemUptime
        values[phase + "MS"] = Int(((now - started) * 1000).rounded())
        started = now
        phase = name
    }
}

func visionMatte(_ image: CGImage, quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) throws -> CVPixelBuffer {
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = quality
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(cgImage:image, options:[:]).perform([request])
    guard let buffer = request.results?.first?.pixelBuffer else { throw ScanFailure.unsupported }
    return buffer
}

func locatePeople(_ image: CGImage) throws -> [PersonAnchor] {
    let factor = max(1, 512 / CGFloat(max(image.width,image.height)))
    let width = max(1, Int(CGFloat(image.width)*factor)), height = max(1, Int(CGFloat(image.height)*factor))
    guard let canvas = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                                 space:rgb,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ScanFailure.unsupported }
    let extent = CGRect(x:0,y:0,width:width,height:height)
    canvas.setFillColor(gray:0.5,alpha:1)
    canvas.fill(extent)
    canvas.interpolationQuality = .high
    canvas.draw(image,in:extent)
    guard let opaque = canvas.makeImage() else { throw ScanFailure.unsupported }
    let bodies = VNDetectHumanRectanglesRequest()
    bodies.upperBodyOnly = false
    let faces = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage:opaque,options:[:]).perform([bodies,faces])
    var anchors = (bodies.results ?? []).filter { $0.confidence >= 0.60 }
        .map { PersonAnchor(box:$0.boundingBox,isFace:false) }
    anchors += (faces.results ?? []).filter { $0.confidence >= 0.72 }
        .map { PersonAnchor(box:$0.boundingBox,isFace:true) }
    if anchors.isEmpty && max(image.width,image.height) <= 96 {
        let border = CGFloat(max(width,height))/4
        let frame = extent.insetBy(dx:-border,dy:-border)
        let framed = CIImage(cgImage:opaque).composited(over:CIImage(color:CIColor(red:0.5,green:0.5,blue:0.5))).cropped(to:frame)
        if let padded = context.createCGImage(framed,from:frame) {
            let retry = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage:padded,options:[:]).perform([retry])
            for face in retry.results ?? [] where face.confidence >= 0.72 {
                let box = face.boundingBox
                let mapped = CGRect(x:(box.minX*frame.width-border)/extent.width,
                    y:(box.minY*frame.height-border)/extent.height,
                    width:box.width*frame.width/extent.width,height:box.height*frame.height/extent.height)
                    .intersection(CGRect(x:0,y:0,width:1,height:1))
                if !mapped.isEmpty { anchors.append(PersonAnchor(box:mapped,isFace:true)) }
            }
        }
    }
    return anchors
}

func scan(_ bytes: Data, settings env: [String: String], trace: ScanTimings) throws -> Data {
    guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
          CGImageSourceGetCount(src) == 1,
          let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
          let w = info[kCGImagePropertyPixelWidth as String] as? Int,
          let h = info[kCGImagePropertyPixelHeight as String] as? Int,
          w > 0, h > 0, w <= 12_000_000 / h else { throw ScanFailure.unsupported }
    if w == 1 && h == 1 { return Data() }
    guard let photo = CIImage(data: bytes, options: [.applyOrientationProperty:true]),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,
            kCGImageSourceThumbnailMaxPixelSize:min(1024,max(w,h))
          ] as CFDictionary) else { throw ScanFailure.unsupported }
    trace.next("localization")
    let anchors = try locatePeople(thumb)
    guard !anchors.isEmpty else { return Data() }
    trace.next("segmentation")
    let small = max(w,h) <= 256
    let primary = small ? try SemanticPeople.mask(thumb) : try visionMatte(thumb)
    trace.next("confirmation")
    let first = try selectPeople(primary, anchors:anchors)
    var mattes = [first]
    let outstanding = anchors.indices.filter { !first.confirmed.contains($0) }.map { anchors[$0] }
    if !outstanding.isEmpty {
        // Rescue a missing person using a different segmenter. A detector box
        // alone never authorizes painting unclassified pixels inside that box.
        trace.next("fallback")
        let alternate = small ? try visionMatte(thumb,quality:.accurate) : try SemanticPeople.mask(thumb)
        mattes.append(try selectPeople(alternate,anchors:outstanding))
    }
    guard mattes.contains(where:{ $0.image != nil }) else { return Data() }
    trace.next("composeGraph")
    let rect = photo.extent
    let margin = min(0.2,max(0,Double(env["FILTER_MARGIN"] ?? "") ?? 0)) * min(rect.width,rect.height)
    var mask = CIImage(color:.black).cropped(to:rect)
    if env["FILTER_SHAPE"] == "Rectangle" {
        for region in mattes.flatMap(\.regions) {
            let box = CGRect(x:rect.minX+region.minX*rect.width,y:rect.minY+region.minY*rect.height,
                             width:region.width*rect.width,height:region.height*rect.height).insetBy(dx:-margin,dy:-margin)
            mask = CIImage(color:.white).cropped(to:box).composited(over:mask).cropped(to:rect)
        }
    } else {
        for matte in mattes.compactMap(\.image) {
            let aligned = matte.transformed(by:CGAffineTransform(scaleX:rect.width/matte.extent.width,
                                                                    y:rect.height/matte.extent.height))
                .transformed(by:CGAffineTransform(translationX:rect.minX,y:rect.minY))
            mask = aligned.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:mask]).cropped(to:rect)
        }
        if margin > 0 { mask = mask.applyingFilter("CIMorphologyMaximum",parameters:["inputRadius":margin]).cropped(to:rect) }
    }
    guard let threshold = CIFilter(name:"CIColorThreshold") else { throw ScanFailure.unsupported }
    threshold.setValue(mask,forKey:kCIInputImageKey)
    threshold.setValue(0.5,forKey:"inputThreshold")
    guard let binaryMask = threshold.outputImage else { throw ScanFailure.unsupported }
    let foreground: CIImage
    if env["FILTER_STYLE"] == "Blur" {
        let strength = min(1,max(0.05,Double(env["FILTER_STRENGTH"] ?? "") ?? 0.35))
        let radius = max(2, min(150, rect.width * strength * 0.1))
        foreground = photo.clampedToExtent().applyingGaussianBlur(sigma:radius).cropped(to:rect)
    } else {
        let hex = UInt32(env["FILTER_COLOR"] ?? "222222",radix:16) ?? 0x222222
        let fill = CIColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255)
        foreground = CIImage(color:fill).cropped(to:rect)
    }
    let painted = foreground.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: photo, kCIInputMaskImageKey: binaryMask
    ]).cropped(to: rect)
    // Compositing the blur can otherwise smear the alpha channel at cutout edges.
    let shaped: CIImage
    if CGImageSourceGetType(src) == UTType.jpeg.identifier as CFString {
        shaped = painted
    } else {
        let opaqueColor = painted.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        shaped = opaqueColor.applyingFilter("CISourceInCompositing",
            parameters: [kCIInputBackgroundImageKey: photo]).cropped(to: rect)
    }
    trace.next("renderEncode")
    guard let png = context.pngRepresentation(of: shaped, format: .RGBA8, colorSpace: rgb),
          png.count <= 32 * 1024 * 1024 else { throw ScanFailure.unsupported }
    return png
}

let defaults = ProcessInfo.processInfo.environment
while let first = read(4) {
    var settings = defaults
    var header = first
    if defaults["FILTER_FRAMED_SETTINGS"] == "1" {
        let length = first.reduce(0) { $0 * 256 + Int($1) }
        guard (2...4096).contains(length), let payload = read(length),
              let values = try? JSONDecoder().decode([String: String].self, from: payload),
              let next = read(4) else { break }
        settings = values
        header = next
    }
    let size = header.reduce(0) { $0 * 256 + Int($1) }
    guard size > 0, size <= 8 * 1024 * 1024, let bytes = read(size) else { break }
    autoreleasepool {
        let result: Data?
        let trace = ScanTimings()
        var failure: String?
        do { result = try scan(bytes, settings: settings, trace: trace) }
        catch {
            let error = error as NSError
            FileHandle.standardError.write(Data("Scan unavailable (\(error.domain) \(error.code))\n".utf8))
            failure = "\(trace.phase) · \(error.domain) (\(error.code))"
            result = nil
        }
        trace.next("finished")
        if defaults["FILTER_WORKER_TIMINGS"] == "1" {
            var meta: [String: Any] = ["stages": trace.values]
            if let failure { meta["failure"] = failure }
            let data = (try? JSONSerialization.data(withJSONObject: meta)) ?? Data("{}".utf8)
            var length = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &length) { output.write(Data($0)) }
            output.write(data)
        }
        var count = (result.map { UInt32($0.count) } ?? UInt32.max).bigEndian
        withUnsafeBytes(of: &count) { output.write(Data($0)) }
        if let result { output.write(result) }
    }
}
