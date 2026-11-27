import AppKit
import CryptoKit

struct Release: Decodable {
    struct Asset: Decodable { let name, browser_download_url: String; let digest: String? }
    let tag_name: String
    let assets: [Asset]
    let draft: Bool
}

enum Updates {
    static let repo = "https://github.com/pmeir99/Mac-Proxy-Filter/releases/download/"
    static func check() async throws -> (String,Release.Asset)? {
        let (data,response) = try await URLSession.shared.data(from:URL(string:"https://api.github.com/repos/pmeir99/Mac-Proxy-Filter/releases?per_page=100")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NetworkSetup.failure("GitHub could not be reached.") }
        let current = Bundle.main.object(forInfoDictionaryKey:"FilterRelease") as? String ?? ""
        let candidates = try JSONDecoder().decode([Release].self,from:data).filter {
            !$0.draft && $0.tag_name.range(of:"^v[0-9]+[.][0-9]+[.][0-9]+-preview[.][0-9]+$",options:.regularExpression) != nil
        }.sorted { $0.tag_name.compare($1.tag_name,options:.numeric) == .orderedDescending }
        for r in candidates where r.tag_name.compare(current,options:.numeric) == .orderedDescending {
            if let asset = r.assets.first(where: {$0.name == "Mac-Proxy-Filter.zip" && $0.browser_download_url == repo+r.tag_name+"/Mac-Proxy-Filter.zip"}) { return (r.tag_name,asset) }
        }
        return nil
    }

    static func prepare(_ asset: Release.Asset, tag: String) async throws -> URL {
        let (archive,response) = try await URLSession.shared.download(from:URL(string:asset.browser_download_url)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NetworkSetup.failure("Download failed.") }
        let hash = SHA256.hash(data:try Data(contentsOf:archive,options:.mappedIfSafe)).map{String(format:"%02x",$0)}.joined()
        guard asset.digest == "sha256:"+hash else { throw NetworkSetup.failure("Download checksum verification failed.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        func run(_ path:String,_ args:[String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath:path); p.arguments = args
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw NetworkSetup.failure("Update verification failed.") }
        }
        do {
            try run("/usr/bin/ditto",["-x","-k",archive.path,folder.path])
            let app = folder.appendingPathComponent("Mac Proxy Filter.app")
            try run("/usr/bin/codesign",["--verify","--deep","--strict",app.path])
            guard let bundle = Bundle(url:app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
                  bundle.object(forInfoDictionaryKey:"FilterRelease") as? String == tag else { throw NetworkSetup.failure("Unexpected update bundle.") }
            return app
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
    }
}
