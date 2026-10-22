import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// A fast reachability check for a *local* HTTP service.
///
/// `TTSManager` asks an engine whether it is available before every
/// synthesis. A full HTTP round-trip is too slow for that, but a TCP connect
/// to loopback takes microseconds — enough to tell "the Drama 3 server is
/// running" from "start it first". Results are cached for a few seconds so a
/// down server is not probed twice in a row.
///
/// Non-loopback hosts are assumed reachable: the request itself reports a
/// remote failure, and probing a remote machine on every synthesis would be
/// worse than the error it prevents.
public final class ServerProbe: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: (checked: Date, ok: Bool)?

    public init() {}

    public func isReachable(_ url: URL,
                            timeout: TimeInterval = 0.25,
                            cacheFor: TimeInterval = 3) -> Bool {
        guard let host = url.host else { return false }
        guard Self.isLoopback(host) else { return true }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)

        lock.lock()
        if let cache, Date().timeIntervalSince(cache.checked) < cacheFor {
            lock.unlock()
            return cache.ok
        }
        lock.unlock()

        let ok = Self.isPortOpen(host: host, port: port, timeout: timeout)

        lock.lock()
        cache = (Date(), ok)
        lock.unlock()
        return ok
    }

    /// True for the addresses that mean "this Mac".
    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "[::1]"
            || host.hasPrefix("127.")
    }

    /// A non-blocking TCP connect with a bounded wait.
    static func isPortOpen(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0,
              let first = list else { return false }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let address = cursor {
            let fd = socket(address.pointee.ai_family,
                            address.pointee.ai_socktype,
                            address.pointee.ai_protocol)
            if fd >= 0 {
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let result = Darwin.connect(fd,
                                            address.pointee.ai_addr,
                                            address.pointee.ai_addrlen)
                if result == 0 {
                    close(fd)
                    return true
                }
                if errno == EINPROGRESS {
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let milliseconds = Int32(max(0, timeout) * 1000)
                    if poll(&descriptor, 1, milliseconds) > 0 {
                        var error: Int32 = 0
                        var length = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0,
                           error == 0 {
                            close(fd)
                            return true
                        }
                    }
                }
                close(fd)
            }
            cursor = address.pointee.ai_next
        }
        return false
    }
}
