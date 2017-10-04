//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO
import Foundation // TODO(JW): investigate linker errors if this is missing

public final class HTTPResponseEncoder : ChannelOutboundHandler {
    public typealias OutboundIn = HTTPResponsePart
    public typealias OutboundOut = ByteBuffer

    private var isChunked = false
    private var scratchBuffer: ByteBuffer

    public init(allocator: ByteBufferAllocator = ByteBufferAllocator()) {
        self.scratchBuffer = allocator.buffer(capacity: 256)
    }

    private func writeChunk(ctx: ChannelHandlerContext, chunk: ByteBuffer, promise: Promise<Void>?) {
        let (mW1, mW2, mW3): (Promise<()>?, Promise<()>?, Promise<()>?)

        switch (self.isChunked, promise) {
        case (true, .some(let p)):
            /* chunked encoding and the user's interested: we need three promises and need to cascade into the users promise */
            let (w1, w2, w3) = (ctx.eventLoop.newPromise() as Promise<()>, ctx.eventLoop.newPromise() as Promise<()>, ctx.eventLoop.newPromise() as Promise<()>)
            w1.futureResult.and(w2.futureResult).and(w3.futureResult).then { _ in () }.cascade(promise: p)
            (mW1, mW2, mW3) = (w1, w2, w3)
        case (false, .some(let p)):
            /* not chunked, so just use the user's promise for the actual data */
            (mW1, mW2, mW3) = (nil, p, nil)
        case (_, .none):
            /* user isn't interested, let's not bother even allocating promises */
            (mW1, mW2, mW3) = (nil, nil, nil)
        }

        /* we don't want to copy the chunk unnecessarily and therefore call write an annoyingly large number of times */
        if self.isChunked {
            self.scratchBuffer.clear()
            let len = String(chunk.readableBytes, radix: 16)
            self.scratchBuffer.write(string: len)
            self.scratchBuffer.write(staticString: "\r\n")
            ctx.write(data: self.wrapOutboundOut(self.scratchBuffer), promise: mW1)
        }
        ctx.write(data: self.wrapOutboundOut(chunk), promise: mW2)
        if self.isChunked {
            self.scratchBuffer.clear()
            self.scratchBuffer.write(staticString: "\r\n")
            ctx.write(data: self.wrapOutboundOut(self.scratchBuffer), promise: mW3)
        }
    }

    public func write(ctx: ChannelHandlerContext, data: IOData, promise: Promise<Void>?) {
        switch self.tryUnwrapOutboundIn(data) {
        case .some(.head(var response)):
            self.isChunked = response.headers["Content-Length"].count == 0
            if self.isChunked {
                response.headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
            }

            self.scratchBuffer.clear()
            response.version.write(buffer: &self.scratchBuffer)
            self.scratchBuffer.write(staticString: " ")
            response.status.write(buffer: &self.scratchBuffer)
            self.scratchBuffer.write(staticString: "\r\n")
            response.headers.write(buffer: &self.scratchBuffer)

            ctx.write(data: self.wrapOutboundOut(self.scratchBuffer), promise: promise)
        case .some(.body(let buffer)):
            self.writeChunk(ctx: ctx, chunk: buffer, promise: promise)
        case .some(.end(let trailers)):
            switch (self.isChunked, promise) {
            case (true, let p):
                self.scratchBuffer.clear()
                if let trailers = trailers {
                    self.scratchBuffer.write(staticString: "0\r\n")
                    trailers.write(buffer: &self.scratchBuffer)  // Includes trailing CRLF.
                } else {
                    self.scratchBuffer.write(staticString: "0\r\n\r\n")
                }
                ctx.write(data: self.wrapOutboundOut(self.scratchBuffer), promise: p)
            case (false, .some(let p)):
                // Not chunked so we have nothing to write. However, we don't want to satisfy this promise out-of-order
                // so we issue a zero-length write down the chain.
                let buf = ctx.channel!.allocator.buffer(capacity: 0)
                ctx.write(data: self.wrapOutboundOut(buf), promise: p)
            case (false, .none):
                break
            }
        case .none:
            ctx.write(data: data, promise: promise)
        }
    }
}
