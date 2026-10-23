// SPDX-License-Identifier: GPL-3.0-or-later
// Port of PhrasingTests.swift: every exact string of SPEC 6, plus the parity cases where Kotlin's standard library
// would differ from Foundation (capitalisation after a hyphen or an apostrophe, half-even km rounding).

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.engine.AlertEvent
import io.github.geiserx.radares.core.engine.DriveContent
import io.github.geiserx.radares.core.engine.Level
import io.github.geiserx.radares.core.health.StretchExitReason
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Radar
import io.github.geiserx.radares.core.model.Role
import io.github.geiserx.radares.core.phrasing.Phrasing
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.Locale

class PhrasingTest {
    private val es = Fixtures.es
    private val en = Fixtures.en

    private fun event(radar: Radar, kind: AlertEvent.Kind = AlertEvent.Kind.Warn(Level.FULL), distance: Double? = 800.0) =
        AlertEvent(kind = kind, radar = radar, distance = distance, content = DriveContent.watching(t0, es))

    private val corridor = makeRadar(kind = Kind.STRETCH, role = Role.MOBILE_CORRIDOR, end = at(41.3, -1.8), road = "N-232", kmFrom = 20.81, kmTo = 30.91, bidirectional = true, source = "dgt_invive")
    private val section = makeRadar(kind = Kind.STRETCH, role = Role.AVERAGE_SPEED_SECTION, end = at(41.3, -1.8), road = "Z-40", kmFrom = 26.6, kmTo = 29.7, maxspeed = 100, directionText = "MADRID")

    @Test
    fun fixedWithLimitAndWithDirection() {
        val p = Phrasing.make(event(makeRadar(road = "A-2", kmFrom = 202.3, maxspeed = 90)), es)
        assertEquals("Radar fijo a 800 metros. Límite 90.", p.spoken)
        assertEquals("Radar fijo a 800 m", p.title)
        assertEquals("A-2 km 202,3 · límite 90 km/h", p.body)
        val q = Phrasing.make(event(makeRadar(directionText = "ZARAGOZA"), distance = 650.0), es)
        assertEquals("Radar fijo a 650 metros, sentido Zaragoza.", q.spoken)
        assertEquals("Radar fijo A-2 km 202.3 · sentido Zaragoza", q.body)
        assertEquals("Radar fijo a 800 metros, sentido Donostia / San Sebastián. Límite 90.", Phrasing.make(event(makeRadar(maxspeed = 90, directionText = "DONOSTIA / SAN SEBASTIÁN")), es).spoken)
    }

    @Test
    fun everyPointKind() {
        assertEquals("Radar de tramo a 600 metros.", Phrasing.make(event(makeRadar(kind = Kind.SECTION), distance = 600.0), es).spoken)
        assertEquals("Radar móvil anunciado a 350 metros. Límite 50.", Phrasing.make(event(makeRadar(kind = Kind.MOBILE_ANNOUNCED, maxspeed = 50), distance = 347.0), es).spoken)
        assertEquals("Radar en remolque a 800 metros.", Phrasing.make(event(makeRadar(kind = Kind.TRAILER)), es).spoken)
        assertEquals("Radar móvil habitual a 350 metros. Límite 50.", Phrasing.make(event(makeRadar(kind = Kind.MOBILE_RECURRING, maxspeed = 50), distance = 347.0), es).spoken)
        assertEquals("Usual mobile radar 800 metres ahead.", Phrasing.make(event(makeRadar(kind = Kind.MOBILE_RECURRING)), en).spoken)
    }

    @Test
    fun stretchJoinedBetweenTheGates() {
        val joined = Phrasing.makeJoined(event(corridor, AlertEvent.Kind.StretchEntered, 4591.0), 4591.0, es)
        assertEquals("Tramo de radar móvil, N-232, quedan 5 kilómetros.", joined.spoken)
        assertEquals("Tramo de radar móvil · quedan 5 kilómetros", joined.title)
        assertEquals("Mobile radar stretch, N-232, 800 metres left.", Phrasing.makeJoined(event(corridor, AlertEvent.Kind.StretchEntered, 800.0), 800.0, en).spoken)
        assertEquals("Radar de tramo, quedan 3 kilómetros, sentido Madrid. Límite 100.", Phrasing.makeJoined(event(section, AlertEvent.Kind.StretchEntered, 2600.0), 2600.0, es).spoken)
    }

    @Test
    fun stretchEntriesAndExit() {
        assertEquals("Tramo de radar móvil, N-232, 10 kilómetros.", Phrasing.make(event(corridor, AlertEvent.Kind.StretchEntered, 610.0), es).spoken)
        val noRoad = makeRadar(kind = Kind.STRETCH, role = Role.MOBILE_CORRIDOR, end = at(41.3, -1.8), kmFrom = 1.0, kmTo = 2.2, bidirectional = true, source = "dgt_invive")
        assertEquals("Tramo de radar móvil, 1 kilómetro.", Phrasing.make(event(noRoad, AlertEvent.Kind.StretchEntered, 610.0), es).spoken)
        val p = Phrasing.make(event(section, AlertEvent.Kind.StretchEntered, 600.0), es)
        assertEquals("Radar de tramo a 600 metros, 3 kilómetros, sentido Madrid. Límite 100.", p.spoken)
        assertEquals("Radar de tramo · 3 kilómetros", p.title)
        assertEquals("Z-40 km 26,6 · límite 100 km/h · sentido Madrid", p.body)
        val exit = Phrasing.make(event(section, AlertEvent.Kind.StretchExited(StretchExitReason.FAR_GATE), null), es)
        assertEquals("Fin de tramo.", exit.spoken)
        assertEquals("Fin de tramo", exit.title)
        assertEquals("", Phrasing.make(event(section, AlertEvent.Kind.Passed, null), es).spoken)
    }

    @Test
    fun combinedSentenceForTwoRadarsOnOneFix() {
        assertEquals("Radar fijo a 600 metros, y otro a 800.", Phrasing.make(event(makeRadar(), distance = 600.0), es, 800.0).spoken)
        assertEquals("Radar fijo a 600 metros, y otro a 800, sentido Zaragoza. Límite 90.", Phrasing.make(event(makeRadar(maxspeed = 90, directionText = "ZARAGOZA"), distance = 600.0), es, 790.0).spoken)
    }

    @Test
    fun english() {
        assertEquals("Fixed speed camera 800 metres ahead. Limit 90.", Phrasing.make(event(makeRadar(maxspeed = 90)), en).spoken)
        assertEquals("Fixed speed camera 650 metres ahead, towards Zaragoza.", Phrasing.make(event(makeRadar(directionText = "ZARAGOZA"), distance = 650.0), en).spoken)
        assertEquals("Announced mobile speed camera 350 metres ahead. Limit 50.", Phrasing.make(event(makeRadar(kind = Kind.MOBILE_ANNOUNCED, maxspeed = 50), distance = 350.0), en).spoken)
        assertEquals("Mobile radar stretch, N-232, 10 kilometres.", Phrasing.make(event(corridor, AlertEvent.Kind.StretchEntered, 610.0), en).spoken)
        assertEquals("End of section.", Phrasing.make(event(corridor, AlertEvent.Kind.StretchExited(StretchExitReason.FAR_GATE), null), en).spoken)
        assertEquals("Fixed speed camera 600 metres ahead, and another at 800.", Phrasing.make(event(makeRadar(), distance = 600.0), en, 800.0).spoken)
        assertEquals("A-2 km 202.3 · limit 90 km/h", Phrasing.make(event(makeRadar(road = "A-2", kmFrom = 202.3, maxspeed = 90)), en).body)
        assertTrue(Phrasing.isEnglish(Locale.forLanguageTag("en-US")))
        assertFalse(Phrasing.isEnglish(Locale.forLanguageTag("es-ES")))
        assertFalse(Phrasing.isEnglish(Locale.forLanguageTag("ca-ES")), "anything but English speaks Spanish")
    }

    @Test
    fun distanceRoundingToFiftyMetresHalfAwayFromZero() {
        assertEquals(850, Phrasing.roundedDistance(833.0))
        assertEquals(800, Phrasing.roundedDistance(824.0))
        assertEquals(850, Phrasing.roundedDistance(825.0), "half away from zero, like Swift's rounded(); half-even would say 800")
        assertEquals(900, Phrasing.roundedDistance(875.0))
        assertEquals(350, Phrasing.roundedDistance(347.0))
        assertEquals(50, Phrasing.roundedDistance(12.0), "never under one step")
        assertEquals(50, Phrasing.roundedDistance(74.99))
        assertEquals(1000, Phrasing.roundedDistance(1000.0))
    }

    @Test
    fun lengthText() {
        assertEquals("10 kilómetros", Phrasing.lengthText(10_100.0, es))
        assertEquals("3 kilómetros", Phrasing.lengthText(3_100.0, es))
        assertEquals("1 kilómetro", Phrasing.lengthText(1_400.0, es))
        assertEquals("3 kilómetros", Phrasing.lengthText(2_500.0, es), "half away from zero")
        assertEquals("950 metros", Phrasing.lengthText(940.0, es))
        assertEquals("1 kilómetro", Phrasing.lengthText(950.0, es))
        assertEquals("87 kilometres", Phrasing.lengthText(86_700.0, en))
    }

    @Test
    fun titlesAndSubtitlesForTheCard() {
        assertEquals("Tramo de radar móvil", Phrasing.kindTitle(makeRadar(kind = Kind.STRETCH, role = Role.MOBILE_CORRIDOR), es))
        assertEquals("Radar de tramo", Phrasing.kindTitle(makeRadar(kind = Kind.STRETCH, role = Role.AVERAGE_SPEED_SECTION), es))
        assertEquals("Radar sin confirmar", Phrasing.kindTitle(makeRadar(kind = Kind.REPORTED), es))
        assertEquals("N-232 km 20,8", Phrasing.subtitle(makeRadar(road = "N-232", kmFrom = 20.81), es))
        assertEquals("N-232", Phrasing.subtitle(makeRadar(road = "N-232"), es))
        assertEquals("Radar anunciado Avenida de Los Antibióticos", Phrasing.subtitle(makeRadar(name = "Radar anunciado Avenida de Los Antibióticos"), es))
    }

    /// Foundation's capitalized(with:), every case run on macOS on 2026-10-23.
    @Test
    fun directionNameMatchesFoundationCapitalized() {
        val cases = mapOf(
            "ZARAGOZA" to "Zaragoza",
            "SANTIAGO DE COMPOSTELA" to "Santiago De Compostela",
            "VITORIA-GASTEIZ" to "Vitoria-Gasteiz",
            "L'HOSPITALET" to "L'hospitalet",
            "SANT JOAN D’ALACANT" to "Sant Joan D’alacant",
            "DONOSTIA / SAN SEBASTIÁN" to "Donostia / San Sebastián",
            "A CORUÑA" to "A Coruña",
            "LLEIDA (CENTRO)" to "Lleida (Centro)",
            "CASTELLÓN/CASTELLÓ" to "Castellón/Castelló",
            "N.SRA.DEL PILAR" to "N.Sra.Del Pilar",
            "2ND ROAD" to "2nd Road",
            "A-2KM" to "A-2km",
            "MADRID_SUR" to "Madrid_sur",
            "ÑANDÚ" to "Ñandú",
        )
        for ((raw, want) in cases) assertEquals(want, Phrasing.directionName(raw, es), raw)
    }

    /// NumberFormatter rounds half to even on the shortest decimal form; every case run on macOS on 2026-10-23.
    @Test
    fun formatKmMatchesNumberFormatter() {
        val cases = mapOf(
            4.25 to "4,2", 4.35 to "4,4", 202.3 to "202,3", 0.05 to "0", 0.15 to "0,2", 0.25 to "0,2",
            1.45 to "1,4", 2.55 to "2,6", 20.81 to "20,8", 1234.56 to "1234,6", 10.0 to "10", 0.95 to "1", 3.05 to "3",
        )
        for ((km, want) in cases) assertEquals(want, Phrasing.formatKm(km, es), "$km")
        assertEquals("202.3", Phrasing.formatKm(202.3, en))
        assertEquals("4.4", Phrasing.formatKm(4.35, en))
    }

    @Test
    fun idleCardTitle() {
        assertEquals("Sin radares cerca", DriveContent.watching(t0, es).title)
        assertEquals("No radars nearby", DriveContent.watching(t0, en).title)
    }
}
