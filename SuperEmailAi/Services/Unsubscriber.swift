import Foundation

enum UnsubscribeError: LocalizedError, Equatable {
    case notHTTPS
    case privateAddress(String)
    case tooManyRedirects
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notHTTPS: "El enlace de baja no es https"
        case .privateAddress(let address): "El enlace de baja apunta a una dirección local (\(address)): no se usa"
        case .tooManyRedirects: "El enlace de baja redirige demasiadas veces"
        case .httpStatus(let status): "El servidor de baja respondió \(status)"
        case .network(let message): message
        }
    }
}

/// RFC 8058 one-click unsubscribe: a POST to the newsletter's https link, with network
/// safeguards (https only, never local names or private/local addresses, at most 5
/// redirects, short timeouts). Success means the server answered 2xx to the POST.
/// Residual risk (inferred, low): without pinning the IP, a DNS change between the check
/// and the connection can't be ruled out entirely.
final class Unsubscriber {
    typealias Resolver = (String) async -> [String]
    static let maxRedirects = 5

    private let session: URLSession
    private let resolve: Resolver

    init(configuration: URLSessionConfiguration = .ephemeral, resolve: @escaping Resolver = DNSResolver.addresses) {
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
        self.resolve = resolve
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        return request
    }

    /// Sends the one-click POST. Throws unless the server answers 2xx.
    func oneClick(_ url: URL) async throws {
        try await check(url)
        let guardian = RedirectGuard { [self] next in try await check(next) }
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: Self.request(for: url), delegate: guardian)
        } catch {
            throw guardian.rejection ?? UnsubscribeError.network(error.localizedDescription)
        }
        if let rejection = guardian.rejection { throw rejection }
        guard let http = response as? HTTPURLResponse else { throw UnsubscribeError.network("Respuesta no HTTP") }
        guard (200...299).contains(http.statusCode) else { throw UnsubscribeError.httpStatus(http.statusCode) }
    }

    /// Only https, never local names, and every resolved address must be public.
    func check(_ url: URL) async throws {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty else {
            throw UnsubscribeError.notHTTPS
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            throw UnsubscribeError.privateAddress(host)
        }
        let addresses = AddressPolicy.isIPLiteral(host) ? [host] : await resolve(host)
        guard !addresses.isEmpty else { throw UnsubscribeError.network("No se pudo resolver \(host)") }
        if let blocked = addresses.first(where: { !AddressPolicy.isPublic($0) }) {
            throw UnsubscribeError.privateAddress(blocked)
        }
    }
}

/// Checks every redirect of one request (same rules as the first URL, at most 5).
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let check: (URL) async throws -> Void
    private(set) var rejection: UnsubscribeError?
    private var redirects = 0

    init(check: @escaping (URL) async throws -> Void) {
        self.check = check
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        redirects += 1
        guard redirects <= Unsubscriber.maxRedirects else {
            rejection = .tooManyRedirects
            return nil
        }
        guard let url = request.url else {
            rejection = .notHTTPS
            return nil
        }
        do {
            try await check(url)
            return request
        } catch {
            rejection = (error as? UnsubscribeError) ?? .network(error.localizedDescription)
            return nil
        }
    }
}

/// Which IP addresses are safe to contact: public ones only.
enum AddressPolicy {
    static func isIPLiteral(_ host: String) -> Bool { ipv4(host) != nil || ipv6(host) != nil }

    /// False for loopback, private, link-local, CGNAT, unspecified, multicast/reserved,
    /// IPv6 local ranges, IPv4-mapped private addresses and anything that isn't an IP.
    static func isPublic(_ ip: String) -> Bool {
        if let b = ipv4(ip) { return isPublicIPv4(b) }
        guard let b = ipv6(ip) else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPublicIPv4(Array(b[12..<16]))                   // ::ffff:a.b.c.d
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 0 || b[15] == 1) { return false }  // :: and ::1
        if b[0] & 0xfe == 0xfc { return false }                       // fc00::/7 (unique local)
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }       // fe80::/10 (link-local)
        if b[0] == 0xff { return false }                              // multicast
        return true
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (169, 254): return false
        case (172, 16...31): return false
        case (192, 168): return false
        case (100, 64...127): return false
        default: return b[0] < 224                                    // multicast, reserved, broadcast
        }
    }

    private static func ipv4(_ s: String) -> [UInt8]? {
        var addr = in_addr()
        guard inet_pton(AF_INET, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }

    private static func ipv6(_ s: String) -> [UInt8]? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, s, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }
}

enum DNSResolver {
    /// Numeric addresses a host resolves to (blocking getaddrinfo, off the calling task).
    static func addresses(_ host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
            defer { freeaddrinfo(first) }
            var out: [String] = []
            var node: UnsafeMutablePointer<addrinfo>? = first
            while let info = node {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    out.append(String(cString: buffer))
                }
                node = info.pointee.ai_next
            }
            return out
        }.value
    }
}
