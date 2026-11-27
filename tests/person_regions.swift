import CoreVideo
import Foundation

@main
struct PersonRegionTests {
    static func check(_ rectangles: [CGRect], anchors: [PersonAnchor]) throws -> SelectedMatte {
        let size = 64
        var optional: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,size,size,kCVPixelFormatType_OneComponent8,nil,&optional) == kCVReturnSuccess)
        let buffer = optional!
        precondition(CVPixelBufferLockBaseAddress(buffer,[]) == kCVReturnSuccess)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<size {
            for x in 0..<size {
                base[y*stride+x] = rectangles.contains { $0.contains(CGPoint(x:x,y:y)) } ? 255 : 0
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer,[])
        return try selectPeople(buffer,anchors:anchors)
    }

    static func main() throws {
        let left = CGRect(x:4,y:8,width:15,height:40)
        let right = CGRect(x:44,y:8,width:15,height:40)
        func body(_ r: CGRect) -> PersonAnchor {
            PersonAnchor(box:CGRect(x:r.minX/64,y:1-r.maxY/64,width:r.width/64,height:r.height/64),isFace:false)
        }
        let single = try check([left,right],anchors:[body(left)])
        precondition(single.regions.count == 1 && single.regions[0] == body(left).box)
        let noise = try check([CGRect(x:5,y:10,width:1,height:1)],anchors:[body(left)])
        precondition(noise.image == nil)
        let bridge = CGRect(x:15,y:30,width:34,height:1)
        let pair = try check([left,right,bridge],anchors:[body(left),body(right)])
        precondition(pair.confirmed == [0,1] && pair.regions.count == 2)
        precondition(!pair.regions.contains { $0.contains(CGPoint(x:0.5,y:0.5)) })
        let thin = try check([CGRect(x:5,y:30,width:13,height:2)],
            anchors:[PersonAnchor(box:body(left).box,isFace:false,objectScore:0.8)])
        precondition(thin.image == nil)
    }
}
