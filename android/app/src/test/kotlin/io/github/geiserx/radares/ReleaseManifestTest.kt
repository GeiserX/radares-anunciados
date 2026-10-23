// SPDX-License-Identifier: GPL-3.0-or-later
//
// The debug-only DebugWakeReceiver (an exported receiver that starts a drive) must never reach a release build.
// Reads the merged manifests Gradle wrote; the debug one is the positive control that the check can see it.

package io.github.geiserx.radares

import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.File

class ReleaseManifestTest {
    private val build = File(requireNotNull(System.getProperty("radares.appBuildDir")))

    private fun merged(variant: String): File {
        val candidates = File(build, "intermediates").walkTopDown()
            .filter { it.name == "AndroidManifest.xml" && it.path.contains("merged_manifest") && it.path.contains("/$variant/") }
            .toList()
        assertTrue(candidates.isNotEmpty(), "no merged $variant manifest under $build")
        return candidates.first()
    }

    @Test
    fun theReleaseManifestHasNoDebugWakeReceiver() {
        val release = merged("release").readText()
        assertTrue(release.contains("DriveService"), "the release manifest was read")
        assertFalse(release.contains("DEBUG_WAKE"))
        assertFalse(release.contains("DebugWakeReceiver"))
    }

    @Test
    fun theDebugManifestHasIt() {
        assertTrue(merged("debug").readText().contains("io.github.geiserx.radares.DEBUG_WAKE"))
    }

    @Test
    fun theManifestAsksForNoForbiddenPermission() {
        val release = merged("release").readText()
        listOf("USE_FULL_SCREEN_INTENT", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "android.permission.WAKE_LOCK\"").forEach {
            assertFalse(release.contains(it), it)
        }
    }
}
