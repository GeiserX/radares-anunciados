// SPDX-License-Identifier: GPL-3.0-or-later
// SPEC 10's budgets: ingest under 10 ms per fix on a 4,500-feature store, decode of a feed-sized file under 500 ms.
// CI runners are shared and noisy, so the assertion allows 3x the budget; the measured figure and its share of the
// real budget are printed on every run, so a regression shows in the log long before it fails.

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.AlertEngine
import io.github.geiserx.radares.core.engine.PassLedger
import io.github.geiserx.radares.core.feed.FeedDecoder
import io.github.geiserx.radares.core.feed.RadarStore
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BudgetTest {
    private val margin = 3.0
    private val feed = Fixtures.syntheticFeed(4500)

    @Test
    fun decodeOfAFeedSizedFile() {
        FeedDecoder.decode(feed) // JIT warm-up, as the app decodes once per launch after class loading
        val runs = 5
        val start = System.nanoTime()
        repeat(runs) { FeedDecoder.decode(feed) }
        val ms = (System.nanoTime() - start) / 1e6 / runs
        println("budget: decode 4,500 features %.1f ms (budget 500 ms, %.0f%%)".format(ms, ms / 500 * 100))
        assertTrue(ms < 500 * margin, "decode took $ms ms")
    }

    @Test
    fun ingestPerFixOnAFeedSizedStore() {
        val store = RadarStore(FeedDecoder.decode(feed))
        assertTrue(store.count >= 3600, "a feed-sized store: ${store.count}")
        val drives = Vector.files().map { Vector.load(it) }.filter { it.negativeControl != true }.map { it.fixList }
        // Warm-up drive, then every vector's fixes through fresh engines.
        AlertEngine(store, PassLedger(), locale = Fixtures.es).let { e -> drives.first().forEach { e.ingest(it) } }
        var fixes = 0
        val start = System.nanoTime()
        for (drive in drives) {
            val engine = AlertEngine(store, PassLedger(), locale = Fixtures.es)
            for (fix in drive) engine.ingest(fix)
            fixes += drive.size
        }
        val ms = (System.nanoTime() - start) / 1e6 / fixes
        println("budget: ingest %.3f ms per fix over %d fixes (budget 10 ms, %.1f%%)".format(ms, fixes, ms / 10 * 100))
        assertTrue(ms < 10 * margin, "ingest took $ms ms per fix")
    }
}
