import Testing
import Foundation
@testable import SuperEmailAi

/// Answers every request with a fixed status and records what it saw (no real network).
final class StubProtocol: URLProtocol {
    static var status = 200
    static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        let url = request.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct UnsubscriberTests {
    private func make(resolvingTo addresses: [String] = ["93.184.216.34"], status: Int = 200) -> Unsubscriber {
        StubProtocol.status = status
        StubProtocol.seen = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return Unsubscriber(configuration: config, resolve: { _ in addresses })
    }

    @Test func requestIsAOneClickPOST() {
        let r = Unsubscriber.request(for: URL(string: "https://example.com/u")!)
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(r.httpBody == Data("List-Unsubscribe=One-Click".utf8))
    }

    @Test func succeedsOn2xx() async throws {
        let unsubscriber = make(status: 200)
        try await unsubscriber.oneClick(URL(string: "https://example.com/u")!)
        #expect(StubProtocol.seen.first?.httpMethod == "POST")
    }

    @Test func failsOnErrorStatus() async {
        let unsubscriber = make(status: 404)
        await #expect(throws: UnsubscribeError.httpStatus(404)) {
            try await unsubscriber.oneClick(URL(string: "https://example.com/u")!)
        }
    }

    @Test func refusesPlainHTTP() async {
        let unsubscriber = make()
        await #expect(throws: UnsubscribeError.notHTTPS) {
            try await unsubscriber.oneClick(URL(string: "http://example.com/u")!)
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test func refusesHostsThatResolveToPrivateAddresses() async {
        let unsubscriber = make(resolvingTo: ["192.168.1.1"])
        await #expect(throws: UnsubscribeError.privateAddress("192.168.1.1")) {
            try await unsubscriber.oneClick(URL(string: "https://router.example/u")!)
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test func refusesLocalNames() async {
        let unsubscriber = make()
        await #expect(throws: UnsubscribeError.privateAddress("localhost")) {
            try await unsubscriber.oneClick(URL(string: "https://localhost/u")!)
        }
        await #expect(throws: UnsubscribeError.privateAddress("impresora.local")) {
            try await unsubscriber.oneClick(URL(string: "https://impresora.local/u")!)
        }
        #expect(StubProtocol.seen.isEmpty)
    }

    @Test func redirectToAPrivateAddressIsRejected() async {
        let guardian = RedirectGuard { url in
            if url.host == "evil.example" { throw UnsubscribeError.privateAddress("10.0.0.1") }
        }
        let origin = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let next = await guardian.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: origin),
                                             willPerformHTTPRedirection: response,
                                             newRequest: URLRequest(url: URL(string: "https://evil.example/x")!))
        #expect(next == nil)
        #expect(guardian.rejection == .privateAddress("10.0.0.1"))
    }

    @Test func atMostFiveRedirects() async {
        let guardian = RedirectGuard { _ in }
        let origin = URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var followed = 0
        for _ in 1...6 {
            let next = await guardian.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: origin),
                                                 willPerformHTTPRedirection: response, newRequest: URLRequest(url: origin))
            if next != nil { followed += 1 }
        }
        #expect(followed == 5)
        #expect(guardian.rejection == .tooManyRedirects)
    }
}

@Test func ipLiteralsAreRecognised() {
    #expect(AddressPolicy.isIPLiteral("127.0.0.1"))
    #expect(AddressPolicy.isIPLiteral("::1"))
    #expect(!AddressPolicy.isIPLiteral("example.com"))
}

@Test(arguments: ["8.8.8.8", "93.184.216.34", "172.32.0.1", "2606:4700::1111"])
func publicAddresses(_ ip: String) {
    #expect(AddressPolicy.isPublic(ip))
}

@Test(arguments: ["10.1.2.3", "127.0.0.1", "192.168.0.10", "172.16.5.4", "172.31.255.255", "169.254.1.1",
                  "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "::", "fe80::1", "fd00::1",
                  "::ffff:192.168.1.1", "no-es-una-ip"])
func privateOrInvalidAddresses(_ ip: String) {
    #expect(!AddressPolicy.isPublic(ip))
}
