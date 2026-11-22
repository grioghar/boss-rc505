import Foundation
#if os(Windows)
import WinSDK
typealias Sock = SOCKET
private let invalidSock: Sock = INVALID_SOCKET
#else
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
import Darwin
#endif
typealias Sock = Int32
private let invalidSock: Sock = -1
#endif

// A small HTTP + WebSocket server on plain sockets, so the same code builds on
// macOS, Linux and Windows without third-party packages. Local use only: it
// binds to 127.0.0.1 and handles one request per HTTP connection.

private enum SocketIO {
    static func setup() {
        #if os(Windows)
        var data = WSADATA()
        _ = WSAStartup(0x0202, &data)
        #else
        signal(SIGPIPE, SIG_IGN)
        #endif
    }

    static func openListener(port: UInt16) -> Sock? {
        #if os(Windows)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #elseif os(Linux)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s != invalidSock else { return nil }
        #if !os(Windows)
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var addr = sockaddr_in()
        addr.sin_family = numericCast(AF_INET)
        addr.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, numericCast(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 16) == 0 else { closeSock(s); return nil }
        return s
    }

    static func acceptClient(_ listener: Sock) -> Sock? {
        let c = accept(listener, nil, nil)
        return c == invalidSock ? nil : c
    }

    static func readSome(_ s: Sock, max: Int = 4096) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: max)
        let n: Int = buffer.withUnsafeMutableBytes { p in
            #if os(Windows)
            return Int(recv(s, p.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(max), 0))
            #else
            return recv(s, p.baseAddress, max, 0)
            #endif
        }
        return n > 0 ? Array(buffer[0..<n]) : nil
    }

    static func writeAll(_ s: Sock, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n: Int = bytes.withUnsafeBytes { p in
                #if os(Windows)
                return Int(send(s, p.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self), Int32(bytes.count - sent), 0))
                #else
                return send(s, p.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                #endif
            }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    static func closeSock(_ s: Sock) {
        #if os(Windows)
        _ = closesocket(s)
        #else
        _ = close(s)
        #endif
    }
}

struct HTTPResponse {
    var status = 200
    var contentType = "application/json"
    var body: [UInt8] = []

    static func json(_ status: Int = 200, _ object: Any) -> HTTPResponse {
        HTTPResponse(status: status, body: Array(jsonString(object).utf8))
    }
    static let notFound = HTTPResponse(status: 404, contentType: "text/plain", body: Array("Not found".utf8))
}

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object), let s = String(data: data, encoding: .utf8) else { return "null" }
    return s
}

/// One browser connection that has upgraded to WebSocket.
final class WebSocketClient {
    fileprivate let sock: Sock
    private let lock = NSLock()
    fileprivate init(sock: Sock) { self.sock = sock }

    @discardableResult
    fileprivate func sendFrame(opcode: UInt8, _ payload: [UInt8]) -> Bool {
        var frame: [UInt8] = [0x80 | opcode]
        if payload.count < 126 { frame.append(UInt8(payload.count)) }
        else if payload.count < 65536 { frame += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] }
        else { frame.append(127); for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) } }
        frame += payload
        lock.lock(); defer { lock.unlock() }
        return SocketIO.writeAll(sock, frame)
    }

    @discardableResult
    func send(_ text: String) -> Bool { sendFrame(opcode: 1, Array(text.utf8)) }
}

final class WebServer {
    var onRequest: (_ path: String) -> HTTPResponse = { _ in .notFound }
    var onSocketOpen: (WebSocketClient) -> Void = { _ in }
    var onSocketMessage: (String) -> Void = { _ in }

    private var clients: [ObjectIdentifier: WebSocketClient] = [:]
    private let lock = NSLock()

    func start(port: UInt16) -> Bool {
        SocketIO.setup()
        guard let listener = SocketIO.openListener(port: port) else { return false }
        Thread.detachNewThread { [weak self] in
            while let sock = SocketIO.acceptClient(listener) {
                Thread.detachNewThread { self?.handle(sock) }
            }
        }
        return true
    }

    func broadcast(_ text: String) {
        lock.lock(); let all = Array(clients.values); lock.unlock()
        for client in all { client.send(text) }
    }

    // MARK: connection handling

    private func handle(_ sock: Sock) {
        defer { SocketIO.closeSock(sock) }
        var buffer: [UInt8] = []
        let terminator: [UInt8] = [13, 10, 13, 10]
        var headerEnd: Int?
        while headerEnd == nil {
            guard buffer.count < 16384, let chunk = SocketIO.readSome(sock) else { return }
            buffer += chunk
            headerEnd = Self.find(terminator, in: buffer)
        }
        guard let end = headerEnd, let head = String(bytes: buffer[0..<end], encoding: .utf8) else { return }
        buffer.removeFirst(end + 4)
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(request[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(sha1(Array((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let reply = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            guard SocketIO.writeAll(sock, Array(reply.utf8)) else { return }
            runSocket(WebSocketClient(sock: sock), leftover: buffer)
            return
        }

        let response = onRequest(path)
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][response.status] ?? "OK"
        let headerText = "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        _ = SocketIO.writeAll(sock, Array(headerText.utf8) + response.body)
    }

    private func runSocket(_ client: WebSocketClient, leftover: [UInt8]) {
        let id = ObjectIdentifier(client)
        lock.lock(); clients[id] = client; lock.unlock()
        defer { lock.lock(); clients[id] = nil; lock.unlock() }
        onSocketOpen(client)

        var buffer = leftover
        // Blocks until `count` bytes are buffered; nil when the peer has gone.
        func take(_ count: Int) -> [UInt8]? {
            while buffer.count < count {
                guard let chunk = SocketIO.readSome(client.sock) else { return nil }
                buffer += chunk
            }
            let out = Array(buffer[0..<count])
            buffer.removeFirst(count)
            return out
        }
        while true {
            guard let head = take(2) else { return }
            let opcode = head[0] & 0x0F
            let masked = head[1] & 0x80 != 0
            var length = Int(head[1] & 0x7F)
            if length == 126 { guard let ext = take(2) else { return }; length = Int(ext[0]) << 8 | Int(ext[1]) }
            else if length == 127 { guard let ext = take(8) else { return }; length = ext.reduce(0) { $0 << 8 | Int($1) } }
            guard length <= 1 << 20 else { return }
            var mask: [UInt8] = [0, 0, 0, 0]
            if masked { guard let m = take(4) else { return }; mask = m }
            guard var payload = take(length) else { return }
            if masked { for i in payload.indices { payload[i] ^= mask[i % 4] } }
            switch opcode {
            case 1: if let text = String(bytes: payload, encoding: .utf8) { onSocketMessage(text) }
            case 8: client.sendFrame(opcode: 8, []); return
            case 9: client.sendFrame(opcode: 10, payload)
            default: break
            }
        }
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return i }
        return nil
    }
}

/// SHA-1, needed only for the WebSocket handshake.
func sha1(_ input: [UInt8]) -> [UInt8] {
    var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    var message = input
    let bitLength = UInt64(input.count) * 8
    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xFF)) }
    for chunk in stride(from: 0, to: message.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            let o = chunk + i * 4
            w[i] = UInt32(message[o]) << 24 | UInt32(message[o + 1]) << 16 | UInt32(message[o + 2]) << 8 | UInt32(message[o + 3])
        }
        for i in 16..<80 { let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = x << 1 | x >> 31 }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
            case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
            default: f = b ^ c ^ d; k = 0xCA62C1D6
            }
            let t = (a << 5 | a >> 27) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = b << 30 | b >> 2; b = a; a = t
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
    }
    return h.flatMap { [UInt8($0 >> 24), UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] }
}
