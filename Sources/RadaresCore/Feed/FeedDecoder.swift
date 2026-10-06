// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later
//
// GeoJSON -> [Radar]: the three direction vocabularies, negative bearings mod 360, section twins merged into
// their stretch, roles by kind and source (design 2.1).

import Foundation

public enum FeedDecoder {
    public static func decode(_ data: Data) throws -> [Radar] {
        fatalError("lane: core")
    }
}
