// Lane: app
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every Spanish literal the screens show has an English entry in the catalog: a phone in English must not show
// one Spanish line in the middle of an English screen.

import XCTest
@testable import RadaresAnunciados

final class LocalizationTests: XCTestCase {
    func testTheEnglishCatalogCoversTheSettingsAndMapLiterals() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"), "the app ships an English localization")
        let en = try XCTUnwrap(Bundle(path: path))
        let keys = [
            "Pausar hoy",
            "Sin «Avisos» la app no se despierta ni usa el GPS. «Pausar hoy» ignora los despertares hasta mañana (en autobús o tren); abrir la app y «Probar aviso» siguen funcionando.",
            "Radar móvil habitual",
            "Radar fijo",
            "Ajustes",
        ]
        for key in keys {
            let value = en.localizedString(forKey: key, value: "MISSING", table: nil)
            XCTAssertNotEqual(value, "MISSING", "no English entry for \(key)")
            XCTAssertNotEqual(value, key, "the English entry for \(key) is the Spanish text")
        }
    }
}
