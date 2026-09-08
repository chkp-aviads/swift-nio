//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics

extension ChannelOptions.Types {
    /// A stable identifier for a `Channel`, assigned when the channel is created.
    ///
    /// Read-only: there is no `setOption` for it, because the identity is the channel's own and
    /// must not change under callers correlating log lines by it.
    ///
    /// The value is an **opaque** string, unique for the lifetime of the process. Do not parse it
    /// or assume a format: `NIOPosix` mints a counter, `NIOTransportServices` a UUID string, and
    /// neither is part of the contract. Treat it as a token to group log lines by.
    ///
    /// Every `Channel` in this package answers it -- `NIOPosix`, `NIOEmbedded` and, out of tree,
    /// `NIOTransportServices` -- so a caller can ask any channel for its id without knowing which
    /// transport built it.
    public struct ChannelID: ChannelOption, Equatable {
        public typealias Value = String
        public init() {}
    }
}

/// Mints `ChannelOptions.Types.ChannelID` values.
///
/// A relaxed atomic counter rather than a random or time-based id: it needs to be unique within
/// the process and cheap enough to pay on every channel, and it deliberately avoids Foundation so
/// that the id keeps working on platforms where Foundation is thin or absent.
public enum ChannelIDGenerator {
    private static let counter = ManagedAtomic<UInt64>(0)

    /// Returns an id no other channel in this process will be given.
    public static func next(prefix: String = "ch") -> String {
        "\(prefix)-\(counter.loadThenWrappingIncrement(ordering: .relaxed))"
    }
}
