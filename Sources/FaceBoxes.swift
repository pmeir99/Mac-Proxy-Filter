import CoreGraphics
import CoreML
import CoreVideo
import Foundation

/// YuNet's compact localizer has three stride heads. The bundled Core ML
/// conversion exposes their channel-first score, box and five-landmark maps.
enum FaceBoxes {
    static let edge = 640
    private static let model: MLModel? = {
        let url = URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/YuNet.mlmodelc")
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf:url,configuration:config)
    }()

    private struct Planes {
        let array: MLMultiArray  // retains the storage
        let pointer: UnsafeMutablePointer<Float>
        let c,y,x: Int
        init(_ output: MLFeatureProvider, _ name: String, side: Int, channels: Int) throws {
            guard let a = output.featureValue(for:name)?.multiArrayValue, a.dataType == .float32,
                  a.shape.suffix(3).map(\.intValue) == [channels,side,side],
                  a.shape.dropLast(3).allSatisfy({ $0.intValue == 1 }) else { throw ScanFailure.unsupported }
            array = a
            pointer = a.dataPointer.assumingMemoryBound(to:Float.self)
            let strides = a.strides.suffix(3).map(\.intValue)
            (c,y,x) = (strides[0],strides[1],strides[2])
        }
        subscript(_ channel:Int,_ row:Int,_ column:Int) -> Double {
            Double(pointer[channel*c + row*y + column*x])
        }
    }

    static func detect(_ image: CGImage) throws -> [PersonAnchor] {
        guard let model else { throw ScanFailure.unsupported }
        var optional: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,edge,edge,kCVPixelFormatType_32BGRA,nil,&optional) == kCVReturnSuccess,
              let buffer = optional, CVPixelBufferLockBaseAddress(buffer,[]) == kCVReturnSuccess else { throw ScanFailure.unsupported }
        let scale = CGFloat(edge)/CGFloat(max(image.width,image.height))
        let width = max(1,(CGFloat(image.width)*scale).rounded()), height = max(1,(CGFloat(image.height)*scale).rounded())
        let draw = CGRect(x:floor((CGFloat(edge)-width)/2),y:floor((CGFloat(edge)-height)/2),width:width,height:height)
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
            guard let base = CVPixelBufferGetBaseAddress(buffer),
                  let ctx = CGContext(data:base,width:edge,height:edge,bitsPerComponent:8,
                    bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpace(name:CGColorSpace.sRGB)!,
                    bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                throw ScanFailure.unsupported
            }
            ctx.setFillColor(gray:0,alpha:1)
            ctx.fill(CGRect(x:0,y:0,width:edge,height:edge))
            ctx.interpolationQuality = .high
            ctx.draw(image,in:draw)
        }
        let input = try MLDictionaryFeatureProvider(dictionary:["input":MLFeatureValue(pixelBuffer:buffer)])
        let output = try model.prediction(from:input)
        var candidates = [(Double,CGRect)]()
        for stride in [8,16,32] {
            let side = edge/stride
            let cls = try Planes(output,"cls_\(stride)",side:side,channels:1)
            let obj = try Planes(output,"obj_\(stride)",side:side,channels:1)
            let box = try Planes(output,"bbox_\(stride)",side:side,channels:4)
            let points = try Planes(output,"kps_\(stride)",side:side,channels:10)
            for row in 0..<side {
                for col in 0..<side {
                    let confidence = sqrt(cls[0,row,col] * obj[0,row,col])
                    guard confidence >= 0.70 else { continue }
                    let step = Double(stride)
                    let cx = (Double(col)+box[0,row,col])*step, cy = (Double(row)+box[1,row,col])*step
                    let w = exp(box[2,row,col])*step, h = exp(box[3,row,col])*step
                    let r = CGRect(x:cx-w/2,y:cy-h/2,width:w,height:h)
                    guard w.isFinite, h.isFinite, w>=4, h>=4 else { continue }
                    let landmarks = (0..<5).map { i in
                        CGPoint(x:(Double(col)+points[2*i,row,col])*step, y:(Double(row)+points[2*i+1,row,col])*step)
                    }
                    let tolerance = r.insetBy(dx:-w*0.1,dy:-h*0.1)
                    guard landmarks.allSatisfy({ tolerance.contains($0) }),
                          hypot(landmarks[0].x-landmarks[4].x,landmarks[0].y-landmarks[4].y) > h*0.16 else { continue }
                    let normalized = CGRect(x:(r.minX-draw.minX)/width,y:(CGFloat(edge)-r.maxY-draw.minY)/height,
                                            width:r.width/width,height:r.height/height)
                        .intersection(CGRect(x:0,y:0,width:1,height:1))
                    if !normalized.isEmpty { candidates.append((confidence,normalized)) }
                }
            }
        }
        var kept = [PersonAnchor]()
        for (_,box) in candidates.sorted(by:{ $0.0 > $1.0 }) {
            let face = PersonAnchor(box:box,isFace:true,landmarks:true)
            if !kept.contains(where:{ sameLocation(face,$0) }) { kept.append(face) }
        }
        return kept
    }
}
