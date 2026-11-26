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
    static let detector: VNCoreMLModel? = {
        let resources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        guard let model = try? MLModel(contentsOf:resources.appendingPathComponent("YOLOv3Int8LUT.mlmodelc")) else { return nil }
        return try? VNCoreMLModel(for:model)
    }()
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
        CVPixelBufferLockBaseAddress(buffer, [])
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

func scan(_ bytes: Data) throws -> Data {
    guard let src = CGImageSourceCreateWithData(bytes as CFData, nil),
          CGImageSourceGetCount(src) == 1,
          let info = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
          let w = info[kCGImagePropertyPixelWidth as String] as? Int,
          let h = info[kCGImagePropertyPixelHeight as String] as? Int,
          w > 0, h > 0, w <= 12_000_000 / h,
          let photo = CIImage(data: bytes, options: [.applyOrientationProperty:true]),
          let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways:true,
            kCGImageSourceCreateThumbnailWithTransform:true,
            kCGImageSourceThumbnailMaxPixelSize:min(1024,max(w,h))
          ] as CFDictionary) else { throw ScanFailure.unsupported }
    let buffer: CVPixelBuffer
    if max(w,h) <= 256 {
        buffer = try SemanticPeople.mask(thumb)
    } else {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cgImage: thumb, options: [:]).perform([request])
        guard let result = request.results?.first?.pixelBuffer else { throw ScanFailure.unsupported }
        buffer = result
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ScanFailure.unsupported }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    var x0 = width, x1 = -1, y0 = height, y1 = -1
    let rectangle = ProcessInfo.processInfo.environment["FILTER_SHAPE"] == "Rectangle"
    rows: for y in 0..<height {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width where row[x] >= 128 { if !rectangle { x1 = x; break rows }; x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y) }
    }
    var fallback: CGRect?
    if x1 < 0 && max(w,h) <= 256 {
        // Rectangle detectors can still localize a face or person when the pixel classifier is empty.
        let factor = 512.0 / CGFloat(max(thumb.width,thumb.height))
        let pw = max(1,Int(CGFloat(thumb.width)*factor)), ph = max(1,Int(CGFloat(thumb.height)*factor))
        guard let canvas = CGContext(data:nil,width:pw,height:ph,bitsPerComponent:8,bytesPerRow:0,
                                     space:rgb,bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ScanFailure.unsupported }
        canvas.interpolationQuality = .high
        canvas.draw(thumb,in:CGRect(x:0,y:0,width:pw,height:ph))
        guard let enlarged = canvas.makeImage() else { throw ScanFailure.unsupported }
        let people = VNDetectHumanRectanglesRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage:enlarged,options:[:])
        try handler.perform([people,faces])
        var boxes = (people.results ?? []).filter { $0.confidence >= 0.6 }.map(\.boundingBox)
                    + (faces.results ?? []).filter { $0.confidence >= 0.6 }.map(\.boundingBox)
        if boxes.isEmpty, let model = SemanticPeople.detector {
            let objects = VNCoreMLRequest(model:model)
            objects.imageCropAndScaleOption = .scaleFill
            try handler.perform([objects])
            boxes = (objects.results as? [VNRecognizedObjectObservation] ?? []).compactMap {
                guard let label = $0.labels.first, label.identifier == "person", label.confidence >= 0.4 else { return nil }
                return $0.boundingBox
            }
        }
        let union = boxes.reduce(CGRect.null) { $0.union($1) }
        if !union.isNull { fallback = union }
    }
    guard x1 >= 0 || fallback != nil else { return Data() }
    let rect = photo.extent
    var mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace:NSNull()])
        .transformed(by: CGAffineTransform(scaleX: rect.width/CGFloat(width), y: rect.height/CGFloat(height)))
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    let env = ProcessInfo.processInfo.environment
    let margin = min(0.2,max(0,Double(env["FILTER_MARGIN"] ?? "") ?? 0)) * min(rect.width,rect.height)
    if let f = fallback {
        let box = CGRect(x:rect.minX+f.minX*rect.width,y:rect.minY+f.minY*rect.height,
                         width:f.width*rect.width,height:f.height*rect.height).insetBy(dx:-margin,dy:-margin)
        mask = CIImage(color:.white).cropped(to:box).composited(over:CIImage(color:.black)).cropped(to:rect)
    } else if env["FILTER_SHAPE"] == "Rectangle" {
        let sx = rect.width/CGFloat(width), sy = rect.height/CGFloat(height)
        let box = CGRect(x: rect.minX+CGFloat(x0)*sx,y: rect.minY+CGFloat(height-1-y1)*sy,
                         width: CGFloat(x1-x0+1)*sx,height: CGFloat(y1-y0+1)*sy).insetBy(dx:-margin,dy:-margin)
        mask = CIImage(color:.white).cropped(to:box).composited(over:CIImage(color:.black)).cropped(to:rect)
    } else if margin > 0 {
        mask = mask.applyingFilter("CIMorphologyMaximum",parameters:["inputRadius":margin]).cropped(to:rect)
    }
    let strength = min(1,max(0.05,Double(env["FILTER_STRENGTH"] ?? "") ?? 0.35))
    let blurred = photo.clampedToExtent().applyingGaussianBlur(sigma: max(2, min(150, rect.width * strength * 0.1))).cropped(to: rect)
    let hex = UInt32(env["FILTER_COLOR"] ?? "222222",radix:16) ?? 0x222222
    let fill = CIColor(red:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255)
    let foreground = env["FILTER_STYLE"] == "Cover" ? CIImage(color:fill).cropped(to:rect) : blurred
    let painted = foreground.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: photo, kCIInputMaskImageKey: mask
    ]).cropped(to: rect)
    // Compositing the blur can otherwise smear the alpha channel at cutout edges.
    let opaqueColor = painted.applyingFilter("CIColorMatrix", parameters: [
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
    ])
    let shaped = opaqueColor.applyingFilter("CISourceInCompositing",
        parameters: [kCIInputBackgroundImageKey: photo]).cropped(to: rect)
    guard let png = context.pngRepresentation(of: shaped, format: .RGBA8, colorSpace: rgb),
          png.count <= 32 * 1024 * 1024 else { throw ScanFailure.unsupported }
    return png
}

while let header = read(4) {
    let size = header.reduce(0) { $0 * 256 + Int($1) }
    guard size > 0, size <= 8 * 1024 * 1024, let bytes = read(size) else { break }
    autoreleasepool {
        let result: Data?
        do { result = try scan(bytes) }
        catch {
            let error = error as NSError
            FileHandle.standardError.write(Data("Scan unavailable (\(error.domain) \(error.code))\n".utf8))
            result = nil
        }
        var count = (result.map { UInt32($0.count) } ?? UInt32.max).bigEndian
        withUnsafeBytes(of: &count) { output.write(Data($0)) }
        if let result { output.write(result) }
    }
}
