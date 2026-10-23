// SPDX-License-Identifier: GPL-3.0-or-later
//
// The product rules in text: nothing tells the driver to open the app before driving, and there is no start or
// stop control. Every string in the app's resources, Spanish and English, plus the health rows' details.

package io.github.geiserx.radares.ui

import io.github.geiserx.radares.Fixtures
import io.github.geiserx.radares.health.HealthInputs
import io.github.geiserx.radares.health.healthReport
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

class ForbiddenTextTest {
    private val forbidden = listOf(
        "abre la app", "abrir la app", "antes de conducir", "iniciar", "detener", "empezar viaje", "parar viaje",
        "open the app", "before you drive", "start drive", "stop drive", "start driving", "stop driving",
    )

    private fun strings(): List<String> {
        val files = Fixtures.resDir.walkTopDown().filter { it.name == "strings.xml" }.toList()
        assertEquals(2, files.size, "values and values-en")
        return files.flatMap { f -> Regex("<string[^>]*>(.*?)</string>").findAll(f.readText()).map { it.groupValues[1] }.toList() }
    }

    @Test
    fun noStringTellsTheDriverToOpenTheAppOrStartAndStop() {
        val texts = strings() + listOf(false, true).flatMap { en -> healthReport(HealthInputs(), en).flatMap { listOf(it.title, it.detail) } }
        assertTrue(texts.size > 50, "${texts.size} texts read")
        val hits = texts.filter { t -> forbidden.any { t.lowercase().contains(it) } }
        assertEquals(emptyList<String>(), hits)
    }

    @Test
    fun theCheckCanFail() {
        val hits = listOf("Abre la app antes de conducir").filter { t -> forbidden.any { t.lowercase().contains(it) } }
        assertEquals(1, hits.size)
    }

    @Test
    fun spanishStringsCarryTheirAccents() {
        val es = File(Fixtures.resDir, "values/strings.xml").readText()
        listOf("Conducción", "Ubicación", "posición", "notificación", "Autocomprobación", "Límite", "Versión", "Fuentes").forEach {
            assertTrue(es.contains(it), it)
        }
        listOf("conduccion ", "ubicacion ", "Autocomprobacion", "Limite ").forEach { assertTrue(!es.contains(it), it) }
    }
}
