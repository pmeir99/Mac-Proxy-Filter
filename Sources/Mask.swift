import Foundation
import CoreImage
import CoreML
import ImageIO
import Vision
import UniformTypeIdentifiers

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

func bundledModel(_ name: String) -> VNCoreMLModel? {
    let resources = URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources")
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    guard let compiled = try? MLModel(contentsOf:resources.appendingPathComponent(name+".mlmodelc"),
                                      configuration:configuration) else { return nil }
    return try? VNCoreMLModel(for:compiled)
}

let objectDetector = bundledModel("YOLOv3Int8LUT")

enum SemanticPeople {
    private static let model = bundledModel("DeepLabV3FP16")

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
    var debugAnchors: [[Double]]?
    var recognition: String?
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

func recognitionRaster(_ image: CGImage) throws -> CGImage {
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
    return opaque
}

func objectPeople(_ image: CGImage) throws -> [PersonAnchor] {
    guard let objectDetector else { throw ScanFailure.unsupported }
    let objects = VNCoreMLRequest(model:objectDetector)
    objects.imageCropAndScaleOption = .scaleFit
    try VNImageRequestHandler(cgImage:image,options:[:]).perform([objects])
    return (objects.results as? [VNRecognizedObjectObservation] ?? []).compactMap { object in
        guard let label = object.labels.first, label.identifier == "person", label.confidence >= 0.35 else { return nil }
        return PersonAnchor(box:object.boundingBox,isFace:false,objectScore:label.confidence)
    }
}

func nativePeople(_ opaque: CGImage, paddedRetry: Bool) throws -> [PersonAnchor] {
    let width = opaque.width, height = opaque.height
    let extent = CGRect(x:0,y:0,width:width,height:height)
    let bodies = VNDetectHumanRectanglesRequest()
    bodies.upperBodyOnly = false
    let faces = VNDetectFaceRectanglesRequest()
    try VNImageRequestHandler(cgImage:opaque,options:[:]).perform([bodies,faces])
    var anchors = (bodies.results ?? []).filter { $0.confidence >= 0.60 }
        .map { PersonAnchor(box:$0.boundingBox,isFace:false) }
    anchors += (faces.results ?? []).filter { $0.confidence >= 0.72 }
        .map { PersonAnchor(box:$0.boundingBox,isFace:true) }
    if anchors.isEmpty && paddedRetry {
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

func sameLocation(_ a: PersonAnchor, _ b: PersonAnchor) -> Bool {
    guard a.isFace == b.isFace else { return false }
    let overlap = a.box.intersection(b.box)
    guard !overlap.isEmpty else { return false }
    let intersection = overlap.width*overlap.height
    return intersection > 0.6 * min(a.box.width*a.box.height,b.box.width*b.box.height)
}

// Confirm small landmark faces that were missed by the full-frame body
// detector. Only examine overlapping crops containing an unresolved face.
// At most four small model runs are shared by all the faces in one image.
func confirmFaces(_ candidates: [Int], anchors: [PersonAnchor], image: CGImage) throws -> Set<Int> {
    var resolved = Set<Int>()
    for y in [0.0,0.36] {
        for x in [0.0,0.36] {
            let frame = CGRect(x:x,y:y,width:0.64,height:0.64)
            let nearby = candidates.filter { !resolved.contains($0) && frame.contains(anchors[$0].box) }
            guard !nearby.isEmpty else { continue }
            let pixels = PersonAnchor(box:frame,isFace:false).inPixels(image.width,image.height)
            guard let crop = image.cropping(to:pixels) else { continue }
            let boxes = try objectPeople(recognitionRaster(crop)).filter { ($0.objectScore ?? 0) >= 0.65 }
            let actual = CGRect(x:pixels.minX/CGFloat(image.width),y:1-pixels.maxY/CGFloat(image.height),
                                width:pixels.width/CGFloat(image.width),height:pixels.height/CGFloat(image.height))
            for index in nearby {
                let face = anchors[index].box
                let local = CGRect(x:(face.minX-actual.minX)/actual.width,y:(face.minY-actual.minY)/actual.height,
                                   width:face.width/actual.width,height:face.height/actual.height)
                if boxes.contains(where:{ candidate in
                    let overlap = candidate.box.intersection(local)
                    return !overlap.isEmpty && overlap.width*overlap.height >= 0.60*local.width*local.height
                }) { resolved.insert(index) }
            }
        }
    }
    return resolved
}

func hands(_ image: CGImage) throws -> [PersonAnchor] {
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 4
    try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])
    return try (request.results ?? []).compactMap { observation in
        let joints = try observation.recognizedPoints(.all)
        guard let wrist = joints[.wrist], wrist.confidence >= 0.4 else { return nil }
        let tips: [VNHumanHandPoseObservation.JointName] = [.thumbTip,.indexTip,.middleTip,.ringTip,.littleTip]
        guard tips.filter({ (joints[$0]?.confidence ?? 0) >= 0.4 }).count >= 2 else { return nil }
        let points = joints.values.filter { $0.confidence >= 0.4 }.map(\.location)
        guard points.count >= 7, let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max(), x1>x0, y1>y0 else { return nil }
        let box = CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
        return PersonAnchor(box:box,isFace:false,hand:true)
    }
}

// Give a small or seated subject its own analysis scale. Candidates still need
// person pixels inside the detected location. Geometry stays in source coordinates.
func rescue(_ anchor: PersonAnchor, in image: CGImage) throws -> SelectedMatte? {
    let width = image.width, height = image.height
    let box = anchor.inPixels(width,height)
    guard !box.isEmpty else { return nil }
    let extraX = box.width * (anchor.isFace ? 0.8 : 0.16)
    let extraY = box.height * (anchor.isFace ? 0.7 : 0.16)
    var crop = box.insetBy(dx:-extraX,dy:-extraY)
    if anchor.isFace { crop.size.height += 2*box.height }
    crop = crop.integral.intersection(CGRect(x:0,y:0,width:width,height:height))
    guard crop.width >= 3, crop.height >= 3, let cutout = image.cropping(to:crop) else { return nil }
    let frame = CGRect(x:crop.minX/CGFloat(width), y:1-crop.maxY/CGFloat(height),
                       width:crop.width/CGFloat(width), height:crop.height/CGFloat(height))
    let local = CGRect(x:(anchor.box.minX-frame.minX)/frame.width, y:(anchor.box.minY-frame.minY)/frame.height,
                       width:anchor.box.width/frame.width,height:anchor.box.height/frame.height)
    var selection = try selectPeople(SemanticPeople.mask(cutout),anchors:[PersonAnchor(box:local,isFace:anchor.isFace,objectScore:anchor.objectScore,landmarks:anchor.landmarks,hand:anchor.hand)])
    guard selection.image != nil else { return nil }
    selection.frame = frame
    selection.regions = selection.regions.map {
        CGRect(x:frame.minX+$0.minX*frame.width,y:frame.minY+$0.minY*frame.height,
               width:$0.width*frame.width,height:$0.height*frame.height)
    }
    return selection
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
    let small = max(w,h) <= 256
    let raster = try recognitionRaster(thumb)
    var anchors = try nativePeople(raster,paddedRetry:max(w,h)<=96)
    trace.next("faceLandmarks")
    anchors += try FaceBoxes.detect(thumb)
    trace.next("objectDetection")
    anchors += try objectPeople(raster)
    trace.next("segmentation")
    let primary = small ? try SemanticPeople.mask(thumb) : try visionMatte(thumb)
    trace.next("confirmation")
    var first = try selectPeople(primary,anchors:anchors)
    if first.unconfirmedRegions > 0 || first.regions.isEmpty && !anchors.isEmpty {
        trace.next("handPose")
        let partial = try hands(raster)
        if !partial.isEmpty {
            anchors += partial
            first = try selectPeople(primary,anchors:anchors)
        }
    }
    guard !anchors.isEmpty else {
        trace.recognition = "No corresponding person detection"
        return Data()
    }
    var confirmed = first.confirmed
    var mattes = [first]
    let missing = anchors.indices.filter { !confirmed.contains($0) }
    let outstanding = missing.map { anchors[$0] }
    let extend = env["FILTER_SHAPE"] != "Rectangle" && first.clipped != nil
    if !outstanding.isEmpty || extend {
        // Rescue a missing person using a different segmenter. A detector box
        // alone never authorizes painting unclassified pixels inside that box.
        trace.next("fallback")
        let alternate = small ? try visionMatte(raster,quality:.accurate) : try SemanticPeople.mask(thumb)
        // A person's arm, lower body or clothing may extend beyond a detector
        // box. Restore those attached pixels only where both segmenters agree.
        if extend, let clipped = first.clipped {
            let support = CIImage(cvPixelBuffer:alternate,options:[.colorSpace:NSNull()])
            let aligned = support.transformed(by:CGAffineTransform(scaleX:clipped.extent.width/support.extent.width,
                                                                     y:clipped.extent.height/support.extent.height))
                .applyingFilter("CIColorThreshold",parameters:["inputThreshold":0.5])
            let overlap = clipped.applyingFilter("CIMinimumCompositing",parameters:[kCIInputBackgroundImageKey:aligned])
            mattes.append(SelectedMatte(image:overlap))
        }
        let second = try selectPeople(alternate,anchors:outstanding)
        mattes.append(second)
        confirmed.formUnion(second.confirmed.map { missing[$0] })
        let remaining = outstanding.indices.filter { !second.confirmed.contains($0) && (outstanding[$0].objectScore ?? 1) >= 0.7 }
            .sorted { outstanding[$0].isFace && !outstanding[$1].isFace }
        for index in remaining.prefix(6) {
            if let recovered = try rescue(outstanding[index],in:thumb) {
                mattes.append(recovered)
                confirmed.insert(missing[index])
            }
        }
    }
    // A verified face can contain a hole in either segmenter (babies, shadows
    // and tightly cropped heads). Fill only its local oval, and only with a
    // second source of evidence in the same location.
    var supportingFaces = Set<Int>()
    var unresolvedFaces = [Int]()
    for index in anchors.indices where anchors[index].landmarks {
        let face = anchors[index].box
        let center = CGPoint(x:face.midX,y:face.midY)
        if confirmed.contains(index) || anchors.contains(where:{ !$0.landmarks && !$0.hand && $0.box.contains(center) }) {
            supportingFaces.insert(index)
        } else { unresolvedFaces.append(index) }
    }
    if !unresolvedFaces.isEmpty {
        trace.next("faceConfirmation")
        supportingFaces.formUnion(try confirmFaces(unresolvedFaces,anchors:anchors,image:thumb))
    }
    let faceOvals = supportingFaces.map { anchors[$0].box }
    let regions = mattes.reduce(0) { $0 + $1.regions.count } + faceOvals.count
    let faces = anchors.filter(\.isFace).count
    let objects = anchors.filter { $0.objectScore != nil }.count
    let handCount = anchors.filter(\.hand).count
    trace.recognition = "\(regions) confirmed regions · \(anchors.count-faces-objects-handCount) Vision bodies, \(faces) faces, \(handCount) hands, \(objects) object-model person detections"
    if defaults["FILTER_TEST_OBSERVATIONS"] == "1" {
        trace.debugAnchors = anchors.prefix(32).map { a in
            [a.isFace ? 1 : 0,Double(a.objectScore ?? -1),a.box.minX,a.box.minY,a.box.width,a.box.height]
                .map { (Double($0)*10_000).rounded()/10_000 }
        }
    }
    guard regions > 0 else { return Data() }
    trace.next("composeGraph")
    let rect = photo.extent
    let margin = min(0.2,max(0,Double(env["FILTER_MARGIN"] ?? "") ?? 0)) * min(rect.width,rect.height)
    var mask = CIImage(color:.black).cropped(to:rect)
    if env["FILTER_SHAPE"] == "Rectangle" {
        for region in mattes.flatMap(\.regions) + faceOvals {
            let box = CGRect(x:rect.minX+region.minX*rect.width,y:rect.minY+region.minY*rect.height,
                             width:region.width*rect.width,height:region.height*rect.height).insetBy(dx:-margin,dy:-margin)
            mask = CIImage(color:.white).cropped(to:box).composited(over:mask).cropped(to:rect)
        }
    } else {
        for selection in mattes {
            guard let matte = selection.image else { continue }
            let frame = selection.frame
            let aligned = matte.transformed(by:CGAffineTransform(scaleX:rect.width*frame.width/matte.extent.width,
                                                                  y:rect.height*frame.height/matte.extent.height))
                .transformed(by:CGAffineTransform(translationX:rect.minX+frame.minX*rect.width,
                                                  y:rect.minY+frame.minY*rect.height))
            mask = aligned.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:mask]).cropped(to:rect)
        }
        for face in faceOvals {
            let box = CGRect(x:rect.minX+face.minX*rect.width,y:rect.minY+face.minY*rect.height,
                             width:face.width*rect.width,height:face.height*rect.height)
            guard let circle = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":CIVector(x:0,y:0),
                "inputRadius0":0.99,"inputRadius1":1.0,"inputColor0":CIColor.white,"inputColor1":CIColor.black])?.outputImage else {
                throw ScanFailure.unsupported
            }
            let oval = circle.transformed(by:CGAffineTransform(scaleX:box.width/2,y:box.height/2))
                .transformed(by:CGAffineTransform(translationX:box.midX,y:box.midY)).cropped(to:box)
            mask = oval.applyingFilter("CIMaximumCompositing",parameters:[kCIInputBackgroundImageKey:mask]).cropped(to:rect)
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
            if let anchors = trace.debugAnchors { meta["anchors"] = anchors }
            if let recognition = trace.recognition { meta["recognition"] = recognition }
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
