import Foundation
@preconcurrency import NIO
@preconcurrency import NIOHTTP1
@preconcurrency import NIOFoundationCompat

public final class NIOProviderServer {
    private let host: String
    private let port: Int
    private let router: ProviderRouter
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    public private(set) var boundPort: Int?

    public init(host: String = "127.0.0.1", port: Int = 8123, router: ProviderRouter) {
        self.host = host
        self.port = port
        self.router = router
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? stop()
    }

    public func start() throws {
        guard channel == nil else { return }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [router] channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(ProviderHTTPHandler(router: router))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        channel = try bootstrap.bind(host: host, port: port).wait()
        boundPort = channel?.localAddress?.port
    }

    public func stop() throws {
        if let channel {
            try channel.close().wait()
            self.channel = nil
            boundPort = nil
        }
        try group.syncShutdownGracefully()
    }
}

private final class ProviderHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let router: ProviderRouter
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(router: ProviderRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let requestHead):
            head = requestHead
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else {
                write(context: context, response: ProviderResponse(status: 400, headers: [:], body: Data()))
                return
            }
            let request = makeRequest(head: head, body: body)
            let router = router
            let writer = ProviderResponseWriter(handler: self, context: context)
            Task {
                do {
                    let result = try await router.route(request)
                    writer.write(result)
                } catch {
                    writer.write(.buffered(ProviderResponse(
                        status: 502,
                        headers: ["content-type": "application/json"],
                        body: Data(#"{"error":"bad gateway"}"#.utf8)
                    )))
                }
            }
        }
    }

    private func makeRequest(head: HTTPRequestHead, body: ByteBuffer) -> ProviderRequest {
        var headers: [String: String] = [:]
        for header in head.headers {
            headers[header.name.lowercased()] = header.value
        }
        var copy = body
        let data = copy.readData(length: copy.readableBytes) ?? Data()
        let uri = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        return ProviderRequest(method: head.method.rawValue, path: uri, headers: headers, body: data)
    }

    fileprivate func write(context: ChannelHandlerContext, response: ProviderResponse) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "content-length", value: String(response.body.count))
        let status = HTTPResponseStatus(statusCode: response.status)
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    fileprivate func writeHead(context: ChannelHandlerContext, response: ProviderStreamedResponse) {
        var headers = HTTPHeaders()
        for (name, value) in response.headers where name.lowercased() != "content-length" {
            headers.add(name: name, value: value)
        }
        headers.replaceOrAdd(name: "transfer-encoding", value: "chunked")
        let status = HTTPResponseStatus(statusCode: response.status)
        context.writeAndFlush(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
            promise: nil
        )
    }

    fileprivate func writeChunk(context: ChannelHandlerContext, data: Data) {
        guard !data.isEmpty else { return }
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    }

    fileprivate func writeEnd(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

private struct ProviderResponseWriter: @unchecked Sendable {
    let handler: ProviderHTTPHandler
    let context: ChannelHandlerContext

    func write(_ result: ProviderRouteResult) {
        context.eventLoop.execute {
            switch result {
            case .buffered(let response):
                handler.write(context: context, response: response)
            case .streamed(let response):
                handler.writeHead(context: context, response: response)
                Task {
                    do {
                        for try await chunk in response.chunks {
                            context.eventLoop.execute {
                                handler.writeChunk(context: context, data: chunk)
                            }
                        }
                    } catch {
                        // The connection is already open; ending it is the least surprising failure mode.
                    }
                    context.eventLoop.execute {
                        handler.writeEnd(context: context)
                    }
                }
            }
        }
    }
}
