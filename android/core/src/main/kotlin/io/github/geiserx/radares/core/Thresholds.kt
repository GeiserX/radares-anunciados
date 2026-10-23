// SPDX-License-Identifier: GPL-3.0-or-later
// Port of Sources/RadaresCore/Thresholds.swift. Every number the design fixes, in one place; the reasons live in the
// Swift file next to each value. Change a value there first, then here, in the same PR.
// Units are in the name: M metres, Mps metres per second, Deg degrees, Seconds, Minutes, Hours, Days.

package io.github.geiserx.radares.core

object Thresholds {
    // Warn distance (design 2.2)
    const val warnLeadSeconds: Double = 25.0
    const val warnFloorM: Double = 300.0
    const val warnCapM: Double = 1000.0
    const val speedMedianFixes: Int = 3

    // Approach test (design 2.3)
    const val aheadDeg: Double = 60.0
    const val bearingToleranceDeg: Double = 90.0
    const val closingFixes: Int = 2
    const val closingMinM: Double = 1.0
    const val candidateBandM: Double = 200.0
    const val lateBandM: Double = 100.0
    const val noVoiceBelowM: Double = 60.0
    const val passedFixes: Int = 3
    const val passedBelowM: Double = 30.0
    const val passedMinRiseM: Double = 3.0
    const val passedCardSeconds: Double = 4.0
    const val courseMinSpeedMps: Double = 3.0
    const val courseFallbackMinM: Double = 15.0
    const val courseFallbackWindowSeconds: Double = 5.0

    // Once per pass and pacing (design 2.6)
    const val cooldownMinutes: Double = 10.0
    const val cooldownM: Double = 2000.0
    const val pacingSeconds: Double = 8.0
    const val ledgerPruneHours: Double = 24.0
    const val ledgerMaxEntries: Int = 200

    // Phrasing (design 2.7)
    const val spokenDistanceStepM: Double = 50.0

    // Driving detection and wake-ups (design 3.1)
    const val driveSpeedMps: Double = 6.0
    const val driveFixes: Int = 3
    const val probeSeconds: Double = 60.0
    const val motionWindowSeconds: Double = 180.0
    const val pauseSlowSeconds: Double = 120.0
    const val pauseSlowSpeedMps: Double = 1.0
    const val resumeSpeedMps: Double = 3.0
    const val pauseEndMinutes: Double = 10.0
    const val fenceRadiusM: Double = 400.0

    // Stretches (design 2.5)
    const val stretchEntryDeg: Double = 60.0
    const val stretchExitGateM: Double = 300.0
    const val stretchExitSlackM: Double = 1000.0
    const val stretchExitTraverseFactor: Double = 2.0
    const val stretchMidJoinFixes: Int = 3
    const val stretchMidJoinCrossTrackM: Double = 150.0

    // Feed (design 5)
    const val feedMinFeatures: Int = 2000
    const val feedTimeoutSeconds: Double = 15.0
    const val refreshForegroundHours: Double = 6.0
    const val refreshBackgroundHours: Double = 6.0
    const val refreshDriveStartHours: Double = 24.0
    const val snapshotMaxAgeDays: Double = 30.0
    const val feedStaleWarnDays: Double = 2.0
    const val feedStaleFailDays: Double = 7.0
    const val feedFailStreak: Int = 3

    // Log and health (design 6)
    const val logMaxLines: Int = 2000
    const val fixLogSeconds: Double = 60.0
    const val healthWindowDays: Double = 7.0
    const val slcSilentDays: Double = 14.0
    const val bgRefreshSilentDays: Double = 3.0
    const val maxGapWarnSeconds: Double = 10.0
    const val selfTestDistanceM: Double = 600.0
    const val healthNoticeHours: Double = 24.0
    const val alertHistoryHours: Double = 24.0
    const val mapRadiusM: Double = 5000.0
    const val spatialIndexRevisitFeatures: Int = 50_000
}
