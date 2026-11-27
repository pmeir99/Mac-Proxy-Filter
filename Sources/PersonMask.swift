import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Vision

enum ScanFailure: Error { case unsupported }

/// Vision reports normalized rectangles from the lower left. Pixel-buffer rows
/// run from the top. Keep that conversion in one place for matching and rendering.
struct PersonAnchor {
    let box: CGRect
    let isFace: Bool
    var objectScore: Float? = nil
    var landmarks = false
    var hand = false

    func inPixels(_ width: Int, _ height: Int) -> CGRect {
        CGRect(x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
               width: box.width * CGFloat(width), height: box.height * CGFloat(height))
            .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    }
}

struct SelectedMatte {
    var frame = CGRect(x:0,y:0,width:1,height:1)
    var image: CIImage?
    var clipped: CIImage?
    var unconfirmedRegions = 0
    var confirmed = Set<Int>()
    var regions = [CGRect]()  // normalized, lower-left coordinates
}

private struct Window {
    let x0, y0, x1, y1: Int
    init(_ rect: CGRect) {
        x0 = Int(rect.minX); y0 = Int(rect.minY)
        x1 = Int(rect.maxX); y1 = Int(rect.maxY)
    }
    func contains(_ x: Int, _ y: Int) -> Bool {
        x >= x0 && y >= y0 && x < x1 && y < y1
    }
}

private struct PixelBounds {
    var left = Int.max, right = -1, top = Int.max, bottom = -1
    mutating func include(x: Int, y: Int) {
        left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
    }
    func normalized(width: Int, height: Int) -> CGRect? {
        guard right >= left else { return nil }
        return CGRect(x:CGFloat(left)/CGFloat(width),y:CGFloat(height-1-bottom)/CGFloat(height),
                      width:CGFloat(right-left+1)/CGFloat(width),height:CGFloat(bottom-top+1)/CGFloat(height))
    }
}

/// A semantic label proposes pixels. Only a component with independent,
/// spatially corresponding human or face evidence can reach the renderer.
func selectPeople(_ buffer: CVPixelBuffer, anchors: [PersonAnchor]) throws -> SelectedMatte {
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard w > 0, h > 0, w <= 4_194_304 / h,
          CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
          CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
        throw ScanFailure.unsupported
    }
    var pixels = [UInt8](repeating: 0, count: w*h)
    do {
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let input = CVPixelBufferGetBaseAddress(buffer) else { throw ScanFailure.unsupported }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeMutableBytes { output in
            for y in 0..<h {
                output.baseAddress!.advanced(by:y*w).copyMemory(from:input.advanced(by:y*stride),byteCount:w)
            }
        }
    }
    var output = Data(count: w*h)
    var clipped = Data()
    var clippedCount = 0
    var selected = SelectedMatte()
    let boxes = anchors.map { $0.inPixels(w,h) }
    let minCore = max(3, w*h/65_536)
    var component = [Int]()
    // 8-connected components preserve diagonal limbs. Weak edge pixels may
    // extend an existing component but cannot seed a decision on their own.
    for seed in pixels.indices where pixels[seed] >= 128 {
        component.removeAll(keepingCapacity: true)
        component.append(seed)
        pixels[seed] = 0
        var head = 0, core = 1
        var left = w, right = 0, top = h, bottom = 0
        while head < component.count {
            let pixel = component[head]
            head += 1
            let y = pixel / w, x = pixel - y*w
            left = min(left,x); right = max(right,x); top = min(top,y); bottom = max(bottom,y)
            for ny in max(0,y-1)...min(h-1,y+1) {
                for nx in max(0,x-1)...min(w-1,x+1) {
                    let next = ny*w+nx
                    let value = pixels[next]
                    if value >= 80 {
                        pixels[next] = 0
                        component.append(next)
                        if value >= 128 { core += 1 }
                    }
                }
            }
        }
        guard core >= minCore else { continue }
        let bounds = CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)
        var matched = [Int]()
        for (index,box) in boxes.enumerated() where !box.isEmpty && bounds.intersects(box) {
            let area = box.width * box.height
            // A thin strip on the edge of an object detection cannot validate
            // a full person. Faces and native body observations have their own geometry.
            let isObject = anchors[index].objectScore != nil
            let minimumFraction: CGFloat = isObject ? 0.14 : (anchors[index].isFace ? 0.16 : 0.025)
            if isObject && bounds.intersection(box).height < box.height * 0.32 { continue }
            let required = max(3, Int(ceil(max(area * minimumFraction,
                                      min(CGFloat(component.count),area) * 0.23))))
            let intersection = bounds.intersection(box)
            if intersection.width*intersection.height < CGFloat(required) { continue }
            let window = Window(box)
            var hits = 0
            for pixel in component {
                let y = pixel / w
                if window.contains(pixel-y*w,y) {
                    hits += 1
                    if hits == required { break }
                }
            }
            if hits >= required { matched.append(index) }
        }
        if matched.isEmpty { selected.unconfirmedRegions += 1; continue }
        let bodies = matched.filter { !anchors[$0].isFace }.map { boxes[$0] }
        let bodyWindows = bodies.map {
            Window($0.insetBy(dx: -0.15*$0.width, dy: -0.12*$0.height).integral)
        }
        // A face without a matching body box can still validate its attached
        // silhouette (close portraits, seated people, partial bodies).
        let standaloneFaces = matched.filter { i in
            anchors[i].isFace && !bodies.contains { $0.contains(CGPoint(x:boxes[i].midX,y:boxes[i].midY)) }
        }.map { CGPoint(x:boxes[$0].midX,y:boxes[$0].midY) }
        var extents = Array(repeating:PixelBounds(),count:bodies.count+standaloneFaces.count)
        output.withUnsafeMutableBytes { (data: UnsafeMutableRawBufferPointer) in
            let bytes = data.bindMemory(to: UInt8.self)
            for pixel in component {
                let y = pixel / w, x = pixel-y*w
                var insideBody = false
                for (i,window) in bodyWindows.enumerated() where window.contains(x,y) {
                    extents[i].include(x:x,y:y)
                    insideBody = true
                }
                if !insideBody {
                    guard !standaloneFaces.isEmpty else {
                        if clipped.isEmpty { clipped = Data(count:w*h) }
                        clipped[pixel] = 255
                        clippedCount += 1
                        continue
                    }
                    var nearest = 0
                    var best = CGFloat.infinity
                    for (i,point) in standaloneFaces.enumerated() {
                        let dx = point.x-CGFloat(x), dy = point.y-CGFloat(y)
                        let distance = dx*dx + dy*dy
                        if distance < best { nearest = i; best = distance }
                    }
                    extents[bodies.count+nearest].include(x:x,y:y)
                }
                bytes[pixel] = 255
            }
        }
        // Keep corroborating locations separate even if the proposed matte had
        // a thin bridge between them that was subsequently clipped away.
        let regions = extents.compactMap { $0.normalized(width:w,height:h) }
        if !regions.isEmpty {
            selected.confirmed.formUnion(matched)
            selected.regions.append(contentsOf:regions)
        }
    }
    if !selected.regions.isEmpty {
        selected.image = CIImage(bitmapData: output, bytesPerRow:w, size:CGSize(width:w,height:h),
                                 format:.L8,colorSpace:nil)
    }
    if clippedCount >= max(16,w*h/160) {
        selected.clipped = CIImage(bitmapData:clipped,bytesPerRow:w,size:CGSize(width:w,height:h),
                                   format:.L8,colorSpace:nil)
    }
    return selected
}
