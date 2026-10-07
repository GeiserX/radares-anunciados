// Lane: frozen (orchestrator)
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Every number the design fixes, in one place, each with the reason it has that value. A lane never
// hardcodes one of these; it reads it from here. Changing a value is an orchestrator PR.
// Units are in the name: M metres, Mps metres per second, Deg degrees, Seconds, Minutes, Hours, Days.

import Foundation

public enum Thresholds {
    // MARK: Warn distance (design 2.2)

    /// Seconds of driving the warning gives the driver: 2 s to notice, 3 s to hear the sentence, 5.6 s to shed 20 km/h at 1 m/s², the rest margin.
    public static let warnLeadSeconds: Double = 25
    /// Floor of the warn distance: a 30 zone would get 208 m at 25 s, 300 m is 36 s there and still a warning.
    public static let warnFloorM: Double = 300
    /// Cap of the warn distance, reached at 144 km/h: beyond 1 km the warning is noise and the radar is more likely on another road.
    public static let warnCapM: Double = 1000
    /// Speed for the warn distance is the median of this many last valid speeds, so one bad fix never moves the distance.
    public static let speedMedianFixes: Int = 3

    // MARK: Approach test (design 2.3)

    /// Max angle between the course and the bearing to the gate for "ahead": a radar on a curve stays inside 60° until the warn distance.
    public static let aheadDeg: Double = 60
    /// Half-plane for the direction gate on a radar with a numeric bearing: only the opposite flow (about 180° apart) is demoted.
    public static let bearingToleranceDeg: Double = 90
    /// Fixes on which the distance must have decreased for "closing": a parallel road or an overpass plateaus or oscillates.
    public static let closingFixes: Int = 2
    /// Minimum decrease per fix that counts as closing, so GPS jitter while stopped is not an approach.
    public static let closingMinM: Double = 1
    /// Candidates are radars within warn distance plus this band, so the candidate set does not flicker at the edge.
    public static let candidateBandM: Double = 200
    /// A radar first seen inside warn distance minus this band still fires, flagged late (late wake-up, GPS warm-up).
    public static let lateBandM: Double = 100
    /// Below this distance and still closing nothing is spoken: the sentence would end after the radar. The notification and the in-app card show it.
    public static let noVoiceBelowM: Double = 60
    /// Passed when the distance increased on this many consecutive fixes after the minimum.
    public static let passedFixes: Int = 3
    /// Passed as well when the distance drops under this, whatever the trend.
    public static let passedBelowM: Double = 30
    /// An increase counts toward passedFixes only when it is at least closingMinM, and the pass also needs the distance
    /// this far (or the fix's horizontal accuracy, whichever is larger) above the minimum: GPS wander while stopped
    /// before a fired radar is not a pass.
    public static let passedMinRiseM: Double = 3
    /// The in-app card shows "Radar superado" for this long, then goes back to watching.
    public static let passedCardSeconds: Double = 4
    /// Below this speed the reported course wanders, so the course comes from the last two fixes instead. Our own threshold, tuned from logged drives.
    public static let courseMinSpeedMps: Double = 3
    /// The two fixes used to derive a course when the platform course is invalid must be at least this far apart.
    public static let courseFallbackMinM: Double = 15
    /// The baseline of a derived course is the most recent fix at least courseFallbackMinM behind within this many
    /// seconds: 15 m in 5 s is courseMinSpeedMps, the same floor as the platform course; slower, the heading wanders.
    public static let courseFallbackWindowSeconds: Double = 5

    // MARK: Once per pass and pacing (design 2.6)

    /// A pass is over only when this many minutes have gone by since firing (and the car has been cooldownM away).
    public static let cooldownMinutes: Double = 10
    /// A pass is over only when the car has been at least this far from the radar since firing (and cooldownMinutes passed).
    public static let cooldownM: Double = 2000
    /// At most one spoken alert per this many seconds; a second radar firing inside the gap is shown, not spoken.
    public static let pacingSeconds: Double = 8
    /// The pass ledger forgets entries older than this; the commute back the next day is a new pass.
    public static let ledgerPruneHours: Double = 24
    /// The pass ledger never holds more entries than this.
    public static let ledgerMaxEntries: Int = 200

    // MARK: Phrasing (design 2.7)

    /// Spoken distances are rounded to this step.
    public static let spokenDistanceStepM: Double = 50

    // MARK: Driving detection and wake-ups (design 3.1)

    /// A fix at or above this speed counts toward "driving": above running, below any road speed.
    public static let driveSpeedMps: Double = 6
    /// This many fixes at driveSpeedMps start a drive.
    public static let driveFixes: Int = 3
    /// The probe iterates the location stream for up to this long: a cold fix can take 30 s and a car leaving a garage 30 s to reach 20 km/h.
    public static let probeSeconds: Double = 60
    /// The motion gate looks back this far: Core Motion reports activities with a delay of up to several minutes.
    public static let motionWindowSeconds: Double = 180
    /// Fixes under pauseSlowSpeedMps for this long pause the drive.
    public static let pauseSlowSeconds: Double = 120
    /// The "slow" speed for pauseSlowSeconds.
    public static let pauseSlowSpeedMps: Double = 1
    /// A resume at or above this speed within pauseEndMinutes continues the same drive.
    public static let resumeSpeedMps: Double = 3
    /// A pause longer than this ends the drive (re-probe on the next update, motion gate first).
    public static let pauseEndMinutes: Double = 10
    /// Radius of the parked fence: Apple's cushion is about 200 m plus 20 s of dwell, so the exit lands about 1 km into the drive at best.
    public static let fenceRadiusM: Double = 400

    // MARK: Stretches (design 2.5)

    /// Entry into a stretch also needs the course within this angle of the chord bearing from the near gate toward the far one.
    public static let stretchEntryDeg: Double = 60
    /// Exit, spoken "Fin de tramo", when within this distance of the far gate.
    public static let stretchExitGateM: Double = 300
    /// Silent exit when the straight-line distance from the entry gate exceeds the stretch length plus this slack: a car on the road is never farther from the entry than the road length.
    public static let stretchExitSlackM: Double = 1000
    /// Silent exit after this many times the traverse time expected at entry speed.
    public static let stretchExitTraverseFactor: Double = 2
    /// A car that joins a stretch between its gates (an on-ramp, a side road) is inside after this many consecutive fixes
    /// that project onto the chord between the gate margins, within stretchMidJoinCrossTrackM of it, with the course along it.
    public static let stretchMidJoinFixes: Int = 3
    /// Max lateral distance from the chord for a mid-stretch join. The chord is not the road (median 0.91 of its length),
    /// so a bowed stretch can be missed; wider would take a parallel road for the stretch.
    public static let stretchMidJoinCrossTrackM: Double = 150

    // MARK: Feed (design 5)

    /// A feed with fewer features than this is refused: today's file has about 4,450.
    public static let feedMinFeatures: Int = 2000
    /// The feed GET gives up after this long; the whole transfer must fit a BGAppRefreshTask's 30 s.
    public static let feedTimeoutSeconds: Double = 15
    /// On foreground, refresh when the feed is older than this; the publisher runs every 6 h.
    public static let refreshForegroundHours: Double = 6
    /// Background refresh task cadence, the publisher's cadence.
    public static let refreshBackgroundHours: Double = 6
    /// At drive start, refresh when the feed is older than this; the download never blocks the alert path.
    public static let refreshDriveStartHours: Double = 24
    /// The bundled snapshot may not be older than this at release time; the release gate goes red otherwise.
    public static let snapshotMaxAgeDays: Double = 30
    /// Estado turns amber when the feed is older than this.
    public static let feedStaleWarnDays: Double = 2
    /// Estado turns red when the feed is older than this. Staleness never disables alerts.
    public static let feedStaleFailDays: Double = 7
    /// Estado turns red when this many consecutive feed attempts failed.
    public static let feedFailStreak: Int = 3

    // MARK: Log and health (design 6)

    /// The event log is rotated at this many lines (about 300 KB).
    public static let logMaxLines: Int = 2000
    /// A fix row is logged at most this often while driving, not every fix.
    public static let fixLogSeconds: Double = 60
    /// Health rows look back this many days for launches, drives and wake-ups.
    public static let healthWindowDays: Double = 7
    /// Significant-change goes red when nothing was delivered in this many days while drives happened.
    public static let slcSilentDays: Double = 14
    /// Background refresh goes amber when no run happened in this many days.
    public static let bgRefreshSilentDays: Double = 3
    /// The last drive goes amber when fixes were this many seconds apart while moving (iOS throttled or suspended us).
    public static let maxGapWarnSeconds: Double = 10
    /// The "Probar aviso" self-test injects a synthetic fixed radar this far ahead on the current heading.
    public static let selfTestDistanceM: Double = 600
    /// A plain (not Time Sensitive) notification about a red Estado is posted at most once per this many hours while the app is closed.
    public static let healthNoticeHours: Double = 24
    /// "Últimos avisos" and the alert history cover this many hours.
    public static let alertHistoryHours: Double = 24
    /// The in-app map shows the radars within this radius.
    public static let mapRadiusM: Double = 5000
    /// The linear candidate scan is the design up to this many features; above it, revisit a spatial index.
    public static let spatialIndexRevisitFeatures: Int = 50_000
}
