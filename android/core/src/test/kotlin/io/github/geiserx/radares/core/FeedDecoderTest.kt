// SPDX-License-Identifier: GPL-3.0-or-later
// Ports of FeedDecoderTests.swift, FeedValidatorTests.swift and RadarStoreTests.swift, plus the strictness the Kotlin
// decoder must share with Swift's JSONDecoder (a type mismatch anywhere rejects the whole file).

package io.github.geiserx.radares.core

import io.github.geiserx.radares.core.feed.FeedDecoder
import io.github.geiserx.radares.core.feed.FeedError
import io.github.geiserx.radares.core.feed.FeedMeta
import io.github.geiserx.radares.core.feed.FeedRefreshPolicy
import io.github.geiserx.radares.core.feed.FeedValidation
import io.github.geiserx.radares.core.feed.FeedValidator
import io.github.geiserx.radares.core.feed.GeoJSONDecodingException
import io.github.geiserx.radares.core.feed.RadarStore
import io.github.geiserx.radares.core.feed.isAlertable
import io.github.geiserx.radares.core.geo.Geo
import io.github.geiserx.radares.core.model.Kind
import io.github.geiserx.radares.core.model.Role
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.params.ParameterizedTest
import org.junit.jupiter.params.provider.ValueSource
import java.time.Instant

class FeedDecoderTest {
    private val store = Fixtures.store

    @Test
    fun theFixtureDecodesToTheExpectedCountsPerKind() {
        val radars = FeedDecoder.decode(Fixtures.feedBytes())
        val counts = radars.groupingBy { it.kind }.eachCount()
        // 254 features: 46 section twins fold into their stretch; the 2 mobile_recurring entries are points.
        assertEquals(208, radars.size)
        assertEquals(109, counts[Kind.FIXED])
        assertEquals(60, counts[Kind.STRETCH])
        assertEquals(4, counts[Kind.SECTION])
        assertEquals(23, counts[Kind.MOBILE_ANNOUNCED])
        assertEquals(2, counts[Kind.MOBILE_RECURRING])
        assertEquals(5, counts[Kind.TRAILER])
        assertEquals(5, counts[Kind.REPORTED])
        assertEquals(radars.size, radars.map { it.id }.toSet().size, "ids stay unique")
    }

    @Test
    fun rolesBySourceAndKind() {
        val roles = store.all.groupingBy { it.role }.eachCount()
        assertEquals(31, roles[Role.MOBILE_CORRIDOR])
        assertEquals(29, roles[Role.AVERAGE_SPEED_SECTION])
        assertEquals(148, roles[Role.POINT])
        assertTrue(store.all.filter { it.kind == Kind.MOBILE_RECURRING }.all { it.role == Role.POINT && it.isAlertable(Instant.now()) }, "a recurring mobile radar is a point with no dates")
        assertEquals(Role.MOBILE_CORRIDOR, Fixtures.radar("dgt_invive-Tramo_Invive_344").role)
        assertEquals(Role.AVERAGE_SPEED_SECTION, Fixtures.radar("dgt-CVM_161274").role)
        assertEquals(Role.AVERAGE_SPEED_SECTION, Fixtures.radar("salamanca-tramo-2").role)
        assertEquals(Role.POINT, Fixtures.radar("dgt-CABINACINEMOMETRO_120001").role)
    }

    @Test
    fun numericDirectionBecomesABearingAndNegativesFoldMod360() {
        val r = Fixtures.radar("osm-619772731")
        assertEquals(320.0, r.bearing)
        assertFalse(r.bidirectional)
        assertNull(r.directionText)
        for (id in listOf("osm-11370481637", "osm-12029827822", "osm-13645871721", "osm-619775424", "osm-992003666", "osm-992004416", "osm-992006870")) {
            val b = store.radar(id)?.bearing ?: error(id)
            assertTrue(b >= 0 && b < 360, id)
        }
        assertEquals(160.0, FeedDecoder.parseDirection("-200").bearing)
        assertEquals(359.0, FeedDecoder.parseDirection("-1").bearing)
        assertEquals(75.0, FeedDecoder.parseDirection("75").bearing)
        assertEquals(40.0, FeedDecoder.parseDirection("400").bearing)
        assertEquals(12.5, FeedDecoder.parseDirection(" 12.5 ").bearing, "trimmed like Swift's .whitespaces")
    }

    @Test
    fun bothNameAndNullVocabularies() {
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        assertTrue(corridor.bidirectional)
        assertNull(corridor.bearing)
        assertNull(corridor.directionText)
        val a2 = Fixtures.radar("dgt-CABINACINEMOMETRO_120001")
        assertEquals("ZARAGOZA", a2.directionText)
        assertNull(a2.bearing)
        assertFalse(a2.bidirectional)
        val pair = Fixtures.radar("dgt-CABINACINEMOMETRO_120452")
        assertNull(pair.directionText)
        assertNull(pair.bearing)
        assertEquals(FeedDecoder.Direction(), FeedDecoder.parseDirection("forward"), "OSM relative tokens carry no heading and no place")
        assertEquals(FeedDecoder.Direction(), FeedDecoder.parseDirection("backward"))
        assertEquals(FeedDecoder.Direction(), FeedDecoder.parseDirection(null))
        assertEquals(FeedDecoder.Direction(), FeedDecoder.parseDirection("  "))
        assertEquals("DONOSTIA / SAN SEBASTIÁN", FeedDecoder.parseDirection("DONOSTIA / SAN SEBASTIÁN").text)
        assertEquals("1-2", FeedDecoder.parseDirection("1-2").text, "digits and dashes that are no number are a name")
    }

    @Test
    fun sectionTwinsMergeIntoTheirStretchBothEnds() {
        assertNull(store.radar("dgt-CVM_161274-from"))
        assertNull(store.radar("dgt-CVM_161274-to"))
        val stretch = Fixtures.radar("dgt-CVM_161274")
        assertEquals(Kind.STRETCH, stretch.kind)
        assertEquals(at(41.6088, -0.915697), stretch.start)
        assertEquals(at(41.6192, -0.9496), stretch.end)
        assertEquals("MADRID", stretch.directionText)
        assertEquals(0, store.all.count { it.id.endsWith("-from") || it.id.endsWith("-to") })
    }

    @Test
    fun unpairedSectionsStayPoints() {
        for (id in listOf("sct-A-2-539.2-545.1", "euskadi-trabakua-tramo-1")) {
            val r = Fixtures.radar(id)
            assertEquals(Kind.SECTION, r.kind)
            assertEquals(Role.POINT, r.role)
            assertNull(r.end)
        }
    }

    @Test
    fun multiVertexLinesKeepTheirPathLength() {
        for (id in listOf("salamanca-tramo-2", "salamanca-tramo-4")) {
            val r = Fixtures.radar(id)
            val straight = Geo.distance(r.start, r.end!!)
            val chord = r.chordMetres!!
            assertTrue(chord > straight, "$id: the sum of the segments is longer than the straight line")
            assertNull(r.roadMetres)
            assertEquals(chord, r.lengthMetres)
        }
    }

    @Test
    fun roadLengthFromKmMarkers() {
        val r = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        assertEquals(10_100.0, r.roadMetres!!, 0.01)
        assertEquals("N-232", r.road)
        assertEquals(20.81, r.kmFrom)
        assertEquals(30.91, r.kmTo)
        assertEquals(r.roadMetres, r.lengthMetres)
        assertEquals(9_680.0, r.chordMetres!!, 60.0)
    }

    @Test
    fun validityDaysAreMadridCalendarDays() {
        val r = Fixtures.radar("leon-2026-10-07-avenida-de-los-antibioticos-2")
        assertEquals(madridDate(2026, 10, 7, 0), r.validFrom)
        assertEquals(madridDate(2026, 10, 7, 0), r.validTo)
        assertEquals(50, r.maxspeed)
        assertTrue(r.active)
        assertFalse(Fixtures.radar("leon-2026-10-06-avenida-de-europa-0").active)
        assertNull(FeedDecoder.day("2026-13-40"))
        assertNull(FeedDecoder.day("2026-02-30"), "no rollover into March")
        assertNull(FeedDecoder.day(null))
        assertEquals(madridDate(2026, 3, 29, 0), FeedDecoder.day("2026-03-29"), "the DST change day starts at Madrid midnight")
    }

    @Test
    fun anAnnouncedMobileRadarIsAlertableOnlyOnItsMadridDays() {
        val leon = Fixtures.radar("leon-2026-10-07-avenida-de-los-antibioticos-2")
        fun ids(day: Instant) = store.candidates(leon.start, 50.0, day).map { it.id }
        assertEquals(listOf(leon.id), ids(madridDate(2026, 10, 7, 0, 1)))
        assertEquals(listOf(leon.id), ids(madridDate(2026, 10, 7, 23, 59)))
        assertEquals(emptyList<String>(), ids(madridDate(2026, 10, 6, 23, 59)))
        assertEquals(emptyList<String>(), ids(madridDate(2026, 10, 8, 0, 1)))
    }

    @Test
    fun madridMidnightNotUtcMidnight() {
        val murcia = store.all.first { it.source == "murcia" && it.active }
        val to = murcia.validTo!!
        assertTrue(murcia.isAlertable(to.plusSeconds(23.5 * 3600)))
        assertFalse(murcia.isAlertable(to.plusSeconds(24.5 * 3600)))
    }

    @Test
    fun candidatesAreOrderedByGateDistanceAndBounded() {
        val a2 = at(41.30326, -1.94488)
        assertEquals(208, store.count)
        assertEquals(listOf("dgt-CABINACINEMOMETRO_120001"), store.candidates(a2, 1200.0, t0).map { it.id })
        val from2km = Geo.destination(a2, 60.0, 2000.0)
        assertTrue(store.candidates(from2km, 1200.0, t0).isEmpty())
        assertEquals(listOf("dgt-CABINACINEMOMETRO_120001"), store.candidates(from2km, 2100.0, t0).map { it.id })
    }

    @Test
    fun aLineIsFoundByItsNearerGateOrByItsChord() {
        val corridor = Fixtures.radar("dgt_invive-Tramo_Invive_344")
        val east = corridor.end!!
        assertEquals(listOf(corridor.id), store.candidates(Geo.destination(east, 90.0, 500.0), 800.0, t0).map { it.id })
        val into = Geo.bearing(corridor.start, east)
        val middle = Geo.destination(corridor.start, into, 4800.0)
        assertEquals(listOf(corridor.id), store.candidates(middle, 1200.0, t0).map { it.id })
        assertEquals(0.0, RadarStore.distance(middle, corridor), 1.0)
        assertTrue(RadarStore.gateDistance(middle, corridor) > 4000)
        val beside = Geo.destination(middle, into + 90, 2000.0)
        assertTrue(store.candidates(beside, 1200.0, t0).isEmpty())
        assertEquals(2000.0, RadarStore.distance(beside, corridor), 5.0)
    }

    @Test
    fun inactiveAndReportedAreNeverCandidates() {
        val inactive = Fixtures.radar("leon-2026-10-06-avenida-de-europa-0")
        assertFalse(store.candidates(inactive.start, 50.0, madridDate(2026, 10, 6)).any { it.id == inactive.id })
        val reported = store.all.first { it.kind == Kind.REPORTED }
        assertTrue(reported.active)
        assertFalse(store.candidates(reported.start, 50.0, t0).any { it.id == reported.id })
        assertEquals("Radar fijo A-2 km 202.3 (sentido ZARAGOZA)", store.radar("dgt-CABINACINEMOMETRO_120001")?.name)
        assertNull(store.radar("nope"))
    }

    @Test
    fun unknownKindsMissingIdsAndOddGeometriesAreSkippedNotFatal() {
        val json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"ok","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true,"maxspeed":null,"direction":null,"province":null,"url":null,"attribution":"a","extra_field":{"nested":1}}},
          {"type":"Feature","id":"newkind","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"drone_patrol","name":"x","source":"dgt","active":true}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","name":"noid","source":"dgt","active":true}},
          {"type":"Feature","id":"poly","geometry":{"type":"Polygon","coordinates":[[[0,0],[1,1],[2,2],[0,0]]]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}},
          {"type":"Feature","id":"nogeom","geometry":null,"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}},
          {"type":"Feature","id":"far","geometry":{"type":"Point","coordinates":[-1.9,91.0]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}}
        ]}
        """.trimIndent()
        assertEquals(listOf("ok"), FeedDecoder.decode(json.toByteArray()).map { it.id })
    }

    @Test
    fun aTwinFillsAMissingLimitOnItsStretch() {
        val json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","id":"s","geometry":{"type":"LineString","coordinates":[[-1.9,41.3],[-1.8,41.3]]},"properties":{"kind":"stretch","name":"s","source":"dgt","active":true,"maxspeed":null,"direction":"MADRID","road":"A-2","km_from":10,"km_to":12.5}},
          {"type":"Feature","id":"s-from","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"section","name":"s from","source":"dgt","active":true,"maxspeed":100}},
          {"type":"Feature","id":"s-to","geometry":{"type":"Point","coordinates":[-1.8,41.3]},"properties":{"kind":"section","name":"s to","source":"dgt","active":true,"maxspeed":100.0}}
        ]}
        """.trimIndent()
        val radars = FeedDecoder.decode(json.toByteArray())
        assertEquals(1, radars.size)
        assertEquals("s", radars[0].id)
        assertEquals(100, radars[0].maxspeed)
        assertEquals(2500.0, radars[0].roadMetres)
    }

    /// Swift's JSONDecoder throws on a value of the wrong JSON type, and FeedValidator turns that into notJSON for the
    /// whole file. The scalar cases (string Int, fractional Int, 1 as Bool, number as String, string Double, 1e400) were
    /// run against Swift on macOS on 2026-10-23; the structural ones follow GeoJSON.swift (required type, [Double]).
    @ParameterizedTest
    @ValueSource(
        strings = [
            """"id":7""",
            """"id":"x","properties":{"kind":"fixed","maxspeed":"50"}""",
            """"id":"x","properties":{"kind":"fixed","maxspeed":50.5}""",
            """"id":"x","properties":{"kind":"fixed","active":1}""",
            """"id":"x","properties":{"kind":"fixed","name":5}""",
            """"id":"x","properties":{"kind":"fixed","km_from":"1.5"}""",
            """"id":"x","properties":{"kind":"fixed","km_from":1e400}""",
            """"id":"x","geometry":{"type":"Point","coordinates":["-1.9",41.3]}""",
            """"id":"x","geometry":{"coordinates":[-1.9,41.3]}""",
            """"id":"x","properties":"fixed"""",
        ],
    )
    fun aTypeMismatchAnywhereRejectsTheWholeFile(feature: String) {
        val good = """{"type":"Feature","id":"ok","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","name":"x","source":"dgt","active":true}}"""
        val bad = """{"type":"Feature",$feature}"""
        val json = """{"type":"FeatureCollection","features":[$good,$bad]}"""
        assertThrows(GeoJSONDecodingException::class.java) { FeedDecoder.decode(json.toByteArray()) }
    }

    /// Swift reads an integral number literal as Int: 50, 50.0 and 5e1 are all 50.
    @Test
    fun anIntegralNumberIsAnInt() {
        for (literal in listOf("50", "50.0", "5e1")) {
            val json = """{"type":"FeatureCollection","features":[{"type":"Feature","id":"ok","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","maxspeed":$literal}}]}"""
            assertEquals(50, FeedDecoder.decode(json.toByteArray()).single().maxspeed, literal)
        }
    }

    /// SPEC 1's optional future fields never reject a file (Swift ignores them) and are kept when well formed.
    @Test
    fun optionalFutureFieldsAreReadLeniently() {
        val json = """{"type":"FeatureCollection","features":[
          {"type":"Feature","id":"a","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","bearing":-90,"direction_semantics":"travel","geometry_is_chord":true,"section_of":"s"}},
          {"type":"Feature","id":"b","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","bearing":"east","direction_semantics":7,"geometry_is_chord":"yes","section_of":3}},
          {"type":"Feature","id":"c","geometry":{"type":"Point","coordinates":[-1.9,41.3]},"properties":{"kind":"fixed","bearing":90}}
        ]}"""
        val radars = FeedDecoder.decode(json.toByteArray()).associateBy { it.id }
        assertEquals(270.0, radars.getValue("a").travelBearing)
        assertEquals(true, radars.getValue("a").geometryIsChord)
        assertEquals("s", radars.getValue("a").sectionOf)
        assertNull(radars.getValue("b").travelBearing)
        assertNull(radars.getValue("b").geometryIsChord)
        assertNull(radars.getValue("c").travelBearing, "a bearing without travel semantics is not a travel bearing")
        assertNull(radars.getValue("a").bearing, "the engine's bearing still comes from `direction` only, as in Swift")
    }

    // Validator, in the order of FeedValidator.swift.

    @Test
    fun aTruncatedFileIsNotJson() {
        val v = FeedValidator.validate(Fixtures.feedBytes().copyOf(5000))
        assertTrue(v is FeedValidation.Invalid && v.error is FeedError.NotJSON, "$v")
    }

    @Test
    fun notAFeatureCollection() {
        assertEquals(FeedValidation.Invalid(FeedError.NotFeatureCollection), FeedValidator.validate("""{"type":"Feature","features":[]}""".toByteArray()))
    }

    @Test
    fun aThousandFeaturesAreTooFew() {
        assertEquals(FeedValidation.Invalid(FeedError.TooFewFeatures(1000)), FeedValidator.validate(Fixtures.syntheticFeed(1000)))
    }

    @Test
    fun aFileWithoutAFixedRadarFails() {
        val data = Fixtures.syntheticFeed(2100) { _, f ->
            val props = f.getValue("properties").jsonObject
            if ((props["kind"] as? JsonPrimitive)?.content == "fixed") JsonObject(f + ("properties" to JsonObject(props + ("kind" to JsonPrimitive("trailer"))))) else f
        }
        assertEquals(FeedValidation.Invalid(FeedError.NoFixedRadar), FeedValidator.validate(data))
    }

    @Test
    fun aFeatureWithoutIdKindOrGeometryFails() {
        val mutations: Map<String, (JsonObject) -> JsonObject> = mapOf(
            "id" to { f -> JsonObject(f - "id") },
            "kind" to { f -> JsonObject(f + ("properties" to JsonObject(f.getValue("properties").jsonObject - "kind"))) },
            "geometry" to { f -> JsonObject(f + ("geometry" to JsonNull)) },
        )
        for ((field, mutate) in mutations) {
            val data = Fixtures.syntheticFeed(2100) { i, f -> if (i == 1700) mutate(f) else f }
            val v = FeedValidator.validate(data)
            assertTrue(v is FeedValidation.Invalid && v.error is FeedError.FeatureMissingField && (v.error as FeedError.FeatureMissingField).field == field, "$field: $v")
        }
    }

    @Test
    fun aFeedSizedFilePasses() {
        val data = Fixtures.syntheticFeed(4500)
        val v = FeedValidator.validate(data)
        assertTrue(v is FeedValidation.Valid, "$v")
        val feed = (v as FeedValidation.Valid).feed
        assertTrue(feed.data.contentEquals(data))
        assertTrue(feed.radars.size >= 3600)
        val fixed = feed.countsByKind.getValue(Kind.FIXED)
        assertTrue(fixed in 109 * 17..109 * 18, "17 full copies of the fixture plus part of an 18th: $fixed")
        assertTrue((feed.countsByKind[Kind.SECTION] ?: 0) <= 4 * 18, "twins fold in a feed-sized file too")
    }

    // Refresh policy and meta.

    @Test
    fun refreshPolicyAgesPerTrigger() {
        val meta = FeedMeta(fetchedAt = t0)
        assertFalse(FeedRefreshPolicy.shouldRefresh(meta, t0.plusSeconds(5.9 * 3600), FeedRefreshPolicy.Trigger.FOREGROUND))
        assertTrue(FeedRefreshPolicy.shouldRefresh(meta, t0.plusSeconds(6 * 3600.0), FeedRefreshPolicy.Trigger.BACKGROUND))
        assertFalse(FeedRefreshPolicy.shouldRefresh(meta, t0.plusSeconds(23 * 3600.0), FeedRefreshPolicy.Trigger.DRIVE_START))
        assertTrue(FeedRefreshPolicy.shouldRefresh(meta, t0.plusSeconds(24 * 3600.0), FeedRefreshPolicy.Trigger.DRIVE_START))
        assertTrue(FeedRefreshPolicy.shouldRefresh(meta, t0, FeedRefreshPolicy.Trigger.MANUAL))
        assertTrue(FeedRefreshPolicy.shouldRefresh(FeedMeta(), t0, FeedRefreshPolicy.Trigger.FOREGROUND), "never fetched")
    }

    @Test
    fun feedMetaRoundTrips() {
        val meta = FeedMeta(etag = "\"abc\"", fetchedAt = t0, checkedAt = t0.plusSeconds(60.0), featureCount = 4450, countsByKind = mapOf(Kind.FIXED to 900, Kind.MOBILE_ANNOUNCED to 30), consecutiveFailures = 1)
        assertEquals(meta, FeedMeta.decode(meta.encode()))
        assertTrue(meta.encode().contains("\"mobile_announced\""))
        assertEquals(FeedMeta(), FeedMeta.decode("garbage"))
        assertNotNull(FeedMeta.decode("{}"))
    }
}
