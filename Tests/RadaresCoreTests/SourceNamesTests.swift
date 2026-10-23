// Lane: core
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest
@testable import RadaresCore

final class SourceNamesTests: XCTestCase {
    func testEveryFixtureSourceHasAName() throws {
        let sources = Set(try Fixtures.sampleStore().all.map(\.source))
        XCTAssertFalse(sources.isEmpty)
        let missing = sources.filter { SourceNames.names[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "sources without a readable name")
    }

    func testNamesAndFallback() {
        XCTAssertEqual(SourceNames.displayName("dgt"), "DGT · radares fijos")
        XCTAssertEqual(SourceNames.displayName("sct"), "Servei Català de Trànsit")
        XCTAssertEqual(SourceNames.displayName("nueva_fuente"), "nueva_fuente")
    }
}
