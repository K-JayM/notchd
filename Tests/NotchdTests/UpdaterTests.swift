import Foundation
@testable import Notchd
import Testing

@Test func versionCompare() throws {
    let v = { (s: String) in try #require(AppVersion(s)) }
    #expect(try v("0.10.0") > v("0.9.3"))     // numeric, not alphabetical
    #expect(try v("v1.2") == v("1.2.0"))      // "v" prefix and missing parts
    #expect(try v("1.2.1") > v("1.2"))
    #expect(AppVersion("1.x") == nil)
    #expect(AppVersion("") == nil)
}

@Test func parseLatestRelease() throws {
    func release(_ tag: String, zip: Bool = true) -> Data {
        let assets = zip ? #"[{"name":"Notchd-\#(tag.dropFirst()).zip","browser_download_url":"https://example.com/n.zip"}]"# : "[]"
        return Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/notchd-app/notchd/releases/\#(tag)","assets":\#(assets)}"#.utf8)
    }
    let current = AppVersion("0.2.0")
    let ok = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)
    let missing = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 404, httpVersion: nil, headerFields: nil)
    let parse = { (data: Data?, response: URLResponse?) in
        Updater.parse(data: data, response: response, error: nil, current: current)
    }

    let update = try parse(release("v0.3.0"), ok).get()
    #expect(update?.version == "0.3.0")
    #expect(update?.zipURL.absoluteString == "https://example.com/n.zip")
    #expect(try parse(release("v0.2.0"), ok).get() == nil)          // same version
    #expect(try parse(release("v0.1.9"), ok).get() == nil)          // older
    #expect(try parse(release("v0.3.0", zip: false), ok).get() == nil)  // release without a build
    #expect(try parse(nil, missing).get() == nil)                   // no release published yet
    #expect(throws: (any Error).self) { try parse(Data("nope".utf8), ok).get() }
}
