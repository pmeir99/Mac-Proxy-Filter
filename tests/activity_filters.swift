import Foundation

@main
struct ActivityFilterTest {
    static func main() {
        func event(_ id:String, _ ms:Int, _ decision:String) -> Event {
            Event(id:id, site:"mail.example", host:"cdn.example", verdict:decision, mime:"image/png",
                  origin:nil, searchText:"cdn.example mail.example thumbnail image/png " + decision.lowercased(), path:"/thumbnail",
                  outcome:decision, method:"GET", failure:nil, processing:[:], cacheHit:nil, time:0,
                  elapsedMS:ms, beforeBytes:1, afterBytes:1, status:200)
        }
        let records = [event("a",50,"Clear"), event("b",101,"Masked"), event("c",500,"Masked")]
        var filter = ActivityFilters(site:"thumbnail PNG, missing",durations:"0-50, 500+",
                                     decisions:["Clear","Masked"], hosts:["mail.example","other"],
                                     methods:["GET","POST"], statuses:["200","403"], types:["image/png","image/gif"])
        precondition(filter.select(records).map(\.id) == ["a","c"])
        filter.durations = "101"
        precondition(filter.select(records).map(\.id) == ["b"])
        filter.durations = "500-10"
        precondition(filter.ranges == nil && filter.select(records).isEmpty)
        precondition(ActivityFilters().select(records).count == 3)
    }
}
