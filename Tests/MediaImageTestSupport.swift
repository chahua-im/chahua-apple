import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

func makeMediaPNG(
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    width: Int = 16,
    height: Int = 16
) throws -> Data {
    let image = try makeSolidMediaImage(
        red: red, green: green, blue: blue, width: width, height: height)
    let data = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

func makeMediaGIF() throws -> Data {
    let frames = [
        try makeSolidMediaImage(red: 255, green: 0, blue: 0, width: 16, height: 16),
        try makeSolidMediaImage(red: 0, green: 255, blue: 0, width: 16, height: 16),
    ]
    let data = NSMutableData()
    let destination = try XCTUnwrap(
        CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
    )
    CGImageDestinationSetProperties(
        destination,
        [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
    for frame in frames {
        CGImageDestinationAddImage(
            destination, frame,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]
            ] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func makeSolidMediaImage(
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    width: Int,
    height: Int
) throws -> CGImage {
    let context = try XCTUnwrap(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    context.setFillColor(
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [CGFloat(red) / 255, CGFloat(green) / 255, CGFloat(blue) / 255, 1]
        )!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try XCTUnwrap(context.makeImage())
}

func makeMediaWebPCheckerboard(animated: Bool = false) throws -> Data {
    let data = try XCTUnwrap(
        Data(
            base64Encoded: """
                UklGRhICAABXRUJQVlA4WAoAAAAgAAAAHwAAHwAASUNDUMgBAAAAAAHIAAAAAAQwAABtbnRyUkdCIFhZWiAH4AABAAEAAAAAAABhY3NwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAA9tYAAQAAAADTLQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAlkZXNjAAAA8AAAACRyWFlaAAABFAAAABRnWFlaAAABKAAAABRiWFlaAAABPAAAABR3dHB0AAABUAAAABRyVFJDAAABZAAAAChnVFJDAAABZAAAAChiVFJDAAABZAAAAChjcHJ0AAABjAAAADxtbHVjAAAAAAAAAAEAAAAMZW5VUwAAAAgAAAAcAHMAUgBHAEJYWVogAAAAAAAAb6IAADj1AAADkFhZWiAAAAAAAABimQAAt4UAABjaWFlaIAAAAAAAACSgAAAPhAAAts9YWVogAAAAAAAA9tYAAQAAAADTLXBhcmEAAAAAAAQAAAACZmYAAPKnAAANWQAAE9AAAApbAAAAAAAAAABtbHVjAAAAAAAAAAEAAAAMZW5VUwAAACAAAAAcAEcAbwBvAGcAbABlACAASQBuAGMALgAgADIAMAAxADZWUDhMIwAAAC8fwAcADzD/8z//8x94EAgkCPtbBjJARP/rUFVVVQUAsL8AAA==
                """))
    guard animated else { return data }

    // Reuse the existing lossless checkerboard, moving it between the halves
    // of a transparent canvas. No second encoded/binary fixture is needed.
    func littleEndian(_ value: Int, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    func chunk(_ name: String, _ payload: Data) -> Data {
        var result = Data(name.utf8)
        result.append(littleEndian(payload.count, count: 4))
        result.append(payload)
        if payload.count % 2 != 0 { result.append(0) }
        return result
    }
    var framePayload = Data()
    var offset = 12
    while offset + 8 <= data.count {
        let name = String(decoding: data[offset..<offset + 4], as: UTF8.self)
        let size = (0..<4).reduce(0) { $0 | Int(data[offset + 4 + $1]) << ($1 * 8) }
        let end = offset + 8 + size + size % 2
        guard end <= data.count else { throw CocoaError(.fileReadCorruptFile) }
        if name == "VP8L" { framePayload = data.subdata(in: offset..<end) }
        offset = end
    }
    guard !framePayload.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
    var extended = Data([0x12, 0, 0, 0])  // Animation and transparency.
    extended.append(littleEndian(63, count: 3))
    extended.append(littleEndian(31, count: 3))
    var body = Data("WEBP".utf8)
    body.append(chunk("VP8X", extended))
    body.append(chunk("ANIM", Data(repeating: 0, count: 6)))
    for x in [0, 16] {  // WebP frame positions are stored in two-pixel units.
        var frame = littleEndian(x, count: 3)
        frame.append(littleEndian(0, count: 3))
        frame.append(littleEndian(31, count: 3))
        frame.append(littleEndian(31, count: 3))
        frame.append(littleEndian(200, count: 3))
        frame.append(3)  // Replace pixels and dispose to the transparent background.
        frame.append(framePayload)
        body.append(chunk("ANMF", frame))
    }
    var result = Data("RIFF".utf8)
    result.append(littleEndian(body.count, count: 4))
    result.append(body)
    return result
}

final class MediaImageFixture: @unchecked Sendable {
    struct Response: Sendable {
        let data: Data
        let cacheControl: String
        let contentType: String
    }

    let url: URL
    private let lock = NSLock()
    private var body: Data
    private var suspended: Bool
    private let cacheControl: String
    private let contentType: String
    private var failure: URLError.Code?
    private var count = 0
    private var pending: [UUID: @Sendable (Result<Response, URLError>) -> Void] = [:]
    private let onRequest: (@Sendable () -> Void)?

    init(
        data: Data,
        contentType: String = "image/png",
        cacheControl: String = "max-age=3600",
        suspended: Bool = false,
        onRequest: (@Sendable () -> Void)? = nil
    ) {
        let pathExtension: String
        switch contentType {
        case "image/gif": pathExtension = "gif"
        case "image/webp": pathExtension = "webp"
        default: pathExtension = "png"
        }
        url = URL(string: "https://image.invalid/\(UUID().uuidString).\(pathExtension)")!
        body = data
        self.contentType = contentType
        self.suspended = suspended
        self.cacheControl = cacheControl
        self.onRequest = onRequest
    }

    var requestCount: Int { lock.withLock { count } }

    func replaceBody(_ data: Data) { lock.withLock { body = data } }

    func suspend() { lock.withLock { suspended = true } }

    func fail(with code: URLError.Code) { lock.withLock { failure = code } }

    private func response() -> Result<Response, URLError> {
        if let failure { return .failure(URLError(failure)) }
        return .success(Response(data: body, cacheControl: cacheControl, contentType: contentType))
    }

    func resume() {
        let (callbacks, result) = lock.withLock {
            suspended = false
            let callbacks = Array(pending.values)
            pending.removeAll()
            return (callbacks, response())
        }
        for callback in callbacks { callback(result) }
    }

    fileprivate func begin(
        id: UUID, completion: @escaping @Sendable (Result<Response, URLError>) -> Void
    ) {
        let result: Result<Response, URLError>? = lock.withLock {
            count += 1
            if suspended {
                pending[id] = completion
                return nil
            }
            return response()
        }
        onRequest?()
        if let result { completion(result) }
    }

    fileprivate func cancel(id: UUID) { _ = lock.withLock { pending.removeValue(forKey: id) } }
}

final class MediaImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let registry = MediaImageFixtureRegistry()
    private let queue = DispatchQueue(label: "MediaImageURLProtocol")
    private let id = UUID()
    private var stopped = false
    private var fixture: MediaImageFixture?

    static func install(_ fixture: MediaImageFixture) { registry.set(fixture, for: fixture.url) }
    static func remove(_ fixture: MediaImageFixture) { registry.set(nil, for: fixture.url) }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "image.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        queue.async {
            guard !self.stopped else { return }
            guard let url = self.request.url, let fixture = Self.registry.get(url) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            self.fixture = fixture
            fixture.begin(id: self.id) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    guard !self.stopped else { return }
                    let received: MediaImageFixture.Response
                    switch result {
                    case .success(let response):
                        received = response
                    case .failure(let error):
                        self.client?.urlProtocol(self, didFailWithError: error)
                        return
                    }
                    let response = HTTPURLResponse(
                        url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Content-Type": received.contentType,
                            "Content-Length": String(received.data.count),
                            "Cache-Control": received.cacheControl,
                        ])!
                    self.client?.urlProtocol(
                        self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: received.data)
                    self.client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    override func stopLoading() {
        queue.async {
            self.stopped = true
            self.fixture?.cancel(id: self.id)
            self.fixture = nil
        }
    }
}

private final class MediaImageFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: MediaImageFixture] = [:]
    func get(_ url: URL) -> MediaImageFixture? { lock.withLock { fixtures[url] } }
    func set(_ fixture: MediaImageFixture?, for url: URL) {
        lock.withLock { fixtures[url] = fixture }
    }
}
