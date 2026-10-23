// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Tests/RadaresCoreTests/SourceNamesTests.swift.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.feed.SourceNames
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class SourceNamesTest {
    @Test fun everyFixtureSourceHasAName() {
        val sources = Fixtures.store.all.map { it.source }.toSet()
        assertTrue(sources.isNotEmpty())
        assertEquals(emptyList<String>(), sources.filter { it !in SourceNames.names }.sorted(), "sources without a readable name")
    }

    @Test fun namesAndFallback() {
        assertEquals("DGT · radares fijos", SourceNames.displayName("dgt"))
        assertEquals("Servei Català de Trànsit", SourceNames.displayName("sct"))
        assertEquals("nueva_fuente", SourceNames.displayName("nueva_fuente"))
    }
}
