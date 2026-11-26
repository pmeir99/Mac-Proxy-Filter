import Foundation
import CoreImage
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
            kCGImageSourceThumbnailMaxPixelSize:1024
          ] as CFDictionary) else { throw ScanFailure.unsupported }
    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(cgImage: thumb, options: [:]).perform([request])
    guard let buffer = request.results?.first?.pixelBuffer else { throw ScanFailure.unsupported }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ScanFailure.unsupported }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    var x0 = width, x1 = -1, y0 = height, y1 = -1
    for y in 0..<height {
        let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width where row[x] >= 128 { x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y) }
    }
    guard x1 >= x0 else { return Data() }
    let rect = photo.extent
    var mask = CIImage(cvPixelBuffer: buffer, options: [.colorSpace:NSNull()])
        .transformed(by: CGAffineTransform(scaleX: rect.width/CGFloat(width), y: rect.height/CGFloat(height)))
        .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    let env = ProcessInfo.processInfo.environment
    let margin = min(0.2,max(0,Double(env["FILTER_MARGIN"] ?? "") ?? 0)) * min(rect.width,rect.height)
    if env["FILTER_SHAPE"] == "Rectangle" {
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
        let result = try? scan(bytes)
        var count = (result.map { UInt32($0.count) } ?? UInt32.max).bigEndian
        withUnsafeBytes(of: &count) { output.write(Data($0)) }
        if let result { output.write(result) }
    }
}
