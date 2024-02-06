//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(Linux) || os(Android)
import DequeModule
import NIOCore

/// A reader which maintains a buffer of bytes read from the file.
///
/// You can create a reader from a ``ReadableFileHandleProtocol`` by calling
/// ``ReadableFileHandleProtocol/bufferedReader(startingAtAbsoluteOffset:capacity:)``. Call
/// ``read(_:)`` to read a fixed number of bytes from the file or ``read(while:)`` to read
/// from the file while the bytes match a predicate.
///
/// You can also read bytes without returning them to caller by calling ``drop(_:)`` and
/// ``drop(while:)``.
@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public struct BufferedReader<Handle: ReadableFileHandleProtocol> {
    /// The handle to read from.
    private let handle: Handle

    /// The offset for the next read from the file.
    private var offset: Int64

    /// Whether the reader has read to the end of the file.
    private var readEOF = false

    /// A buffer containing the read bytes.
    private var buffer: ByteBuffer

    /// The capacity of the buffer.
    public let capacity: Int

    /// The number of bytes currently in the buffer.
    public var count: Int {
        return self.buffer.readableBytes
    }

    internal init(wrapping readableHandle: Handle, initialOffset: Int64, capacity: Int) {
        precondition(
            initialOffset >= 0,
            "initialOffset (\(initialOffset)) must be greater than or equal to zero"
        )
        precondition(capacity > 0, "capacity (\(capacity)) must be greater than zero")
        self.handle = readableHandle
        self.offset = initialOffset
        self.capacity = capacity
        self.buffer = ByteBuffer()
    }

    private mutating func readFromFile(_ count: Int) async throws -> ByteBuffer {
        let bytes = try await self.handle.readChunk(
            fromAbsoluteOffset: self.offset,
            length: .bytes(Int64(count))
        )
        // Reading short means reading end-of-file.
        self.readEOF = bytes.readableBytes < count
        self.offset += Int64(bytes.readableBytes)
        return bytes
    }

    /// Read at most `count` bytes from the file; reads short if not enough bytes are available.
    ///
    /// - Parameters:
    ///   - count: The number of bytes to read.
    /// - Returns: The bytes read from the buffer.
    public mutating func read(_ count: ByteCount) async throws -> ByteBuffer {
        let byteCount = Int(count.bytes)
        guard byteCount > 0 else { return ByteBuffer() }

        if let bytes = self.buffer.readSlice(length: byteCount) {
            return bytes
        } else {
            // Not enough bytes: read enough for the caller and to fill the buffer back to capacity.
            var buffer = self.buffer
            self.buffer = ByteBuffer()

            let bytesFromChunk = byteCount &- buffer.readableBytes
            let bytesToRead = bytesFromChunk + self.capacity

            let chunk = try await self.readFromFile(bytesToRead)
            self.buffer.writeImmutableBuffer(chunk)

            if let readBytes = self.buffer.readSlice(length: bytesFromChunk) {
                buffer.writeImmutableBuffer(readBytes)
            }

            return buffer
        }
    }

    /// Reads from  the current position in the file until `predicate` returns `false` and returns
    /// the read bytes.
    ///
    /// - Parameters:
    ///   - predicate: A predicate which evaluates to `true` for all bytes returned.
    /// - Returns: The bytes read from the file.
    public mutating func read(
        while predicate: (UInt8) -> Bool
    ) async throws -> ByteBuffer {
        // Check if the required bytes are in the buffer already.
        let view = self.buffer.readableBytesView

        if let index = view.firstIndex(where: { !predicate($0) }) {
            // Got an index; slice off the front of the buffer.
            let prefix = view[..<index]
            let buffer = ByteBuffer(prefix)
            self.buffer.moveReaderIndex(forwardBy: buffer.readableBytes)
            return buffer
        }

        // The predicate holds true for all bytes in the buffer, start consuming chunks from the
        // iterator.
        while !self.readEOF {
            var chunk = try await self.readFromFile(self.capacity)
            let view = chunk.readableBytesView

            if let index = view.firstIndex(where: { !predicate($0) }) {
                // Found a byte for which the predicate doesn't hold. Consume the entire buffer and
                // the front of this slice.
                let chunkPrefix = view[..<index]
                self.buffer.writeBytes(chunkPrefix)
                chunk.moveReaderIndex(forwardBy: chunkPrefix.count)

                let buffer = self.buffer
                self.buffer = chunk

                // Store the rest of the chunk.
                return buffer
            } else {
                // Predicate holds for all bytes. Continue reading.
                self.buffer.writeBuffer(&chunk)
            }
        }

        // Read end-of-file without hitting the predicate: clear the buffer and return all bytes.
        let buffer = self.buffer
        self.buffer = ByteBuffer()
        return buffer
    }

    /// Reads and discards the given number of bytes.
    ///
    /// - Parameter count: The number of bytes to read and discard.
    public mutating func drop(_ count: Int) async throws {
        if count > self.buffer.readableBytes {
            self.offset += Int64(count &- self.buffer.readableBytes)
            self.buffer.clear()
        } else {
            self.buffer.moveReaderIndex(forwardBy: count)
        }
    }

    /// Reads and discards bytes until `predicate` returns `false.`
    ///
    /// - Parameters:
    ///   - predicate: A predicate which evaluates to `true` for all dropped bytes.
    public mutating func drop(while predicate: (UInt8) -> Bool) async throws {
        let view = self.buffer.readableBytesView

        if let index = view.firstIndex(where: { !predicate($0) }) {
            let slice = view[..<index]
            self.buffer.moveReaderIndex(forwardBy: slice.count)
            return
        }

        // Didn't hit the predicate for buffered bytes; drop them all and consume the source.
        self.buffer.clear(minimumCapacity: min(self.buffer.capacity, self.capacity))

        while !self.readEOF {
            var chunk = try await self.readFromFile(self.capacity)
            let view = chunk.readableBytesView

            if let index = view.firstIndex(where: { !predicate($0) }) {
                let slice = view[..<index]
                chunk.moveReaderIndex(forwardBy: slice.count)
                self.buffer.writeBuffer(&chunk)
                return
            }
        }
    }
}

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
extension ReadableFileHandleProtocol {
    /// Creates a new ``BufferedReader`` for this file handle.
    ///
    /// - Parameters:
    ///   - initialOffset: The offset to begin reading from, defaults to zero.
    ///   - capacity: The capacity of the buffer in bytes, as a ``ByteCount``. Defaults to 512 KiB.
    /// - Returns: A ``BufferedReader``.
    public func bufferedReader(
        startingAtAbsoluteOffset initialOffset: Int64 = 0,
        capacity: ByteCount = .kibibytes(512)
    ) -> BufferedReader<Self> {
        return BufferedReader(wrapping: self, initialOffset: 0, capacity: Int(capacity.bytes))
    }
}

#endif
