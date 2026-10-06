# Radares Anunciados, iPhone app: design

Design, 2026-10-07. Every claim with a URL was checked on that date. Feed numbers were measured on 2026-10-06 on `https://geiserx.github.io/radares-anunciados-ha/feed.geojson` (2,885,752 bytes, ETag `"6ac53e00-2c0878"`, Last-Modified 2026-10-06 18:29 UTC, 4,452 features; 156,615 bytes gzipped locally, about 172 KB as served).

The idea that drives the whole design: **iOS will suspend, kill, relaunch and reboot this app, and the driver must never notice.** Every piece of state the warning depends on is either owned by iOS (system-persisted wake-ups) or re-created in the first second of every launch, in `application(_:didFinishLaunchingWithOptions:)`, without waiting for a scene, a view or the network. The alert maths, the feed and the surfaces are built so they can be re-entered from any of those launches.

Repo `GeiserX/radares-anunciados`, Swift 6, Swift package `RadaresCore` at the root plus XcodeGen app `App/project.yml`, app target `RadaresAnunciados` + widget extension `RadaresWidgets`, deployment target iOS 18.0 (the `CLServiceSession` and `supplementalActivityFamilies` floor; the CarPlay card needs iOS 26 at run time), iPhone only, GPL-3.0-or-later, no server, no account, no analytics, no push. Android later from section 12.

---

## 0. The moment on the road (acceptance criteria)

Three pictures; everything below exists to deliver them. They are also the three cases of `scripts/sim-drive.sh` and the top of `docs/SPEC.md`.

**120 km/h, A-2, fixed radar `dgt-CABINACINEMOMETRO_120001` at km 202.3, direction text "ZARAGOZA", limit unknown.** The car screen (CarPlay Dashboard, iOS 26) already shows a small card `Radar fijo · 1,0 km`, stepping down at 1,000, 750, 500, 250 and 100 m (the Live Activity is budgeted by the system, so the card shows milestones, not a countdown; the voice carries the exact distance). At 833 m the car's speakers say once, over the music, which ducks: *"Radar fijo a ochocientos metros, sentido Zaragoza."* The card reaches `100 m`, shows `Radar superado` for four seconds, then `Sin radares cerca`. Driving the other way past the same radar the app also warns (the feed gives a town name, not a bearing; the sentence says the direction so the driver judges).

**90 km/h, N-232, `dgt_invive` mobile-radar stretch `dgt_invive-Tramo_Invive_344`, km 20.81 to 30.91 (10.1 km), direction `both`.** At 625 m from the nearer endpoint, heading into the stretch: *"Tramo de radar móvil, N-232, diez kilómetros."* The card shows `Tramo radar móvil · N-232 · 8,5 km restantes` for the whole stretch, the remaining figure moving in 500 m steps. Near the far end: *"Fin de tramo."* and the badge goes.

**50 km/h, Avenida de Europa (León), police weekly list, limit 50, `valid_from` = `valid_to` = today.** At 347 m: *"Radar móvil anunciado a trescientos cincuenta metros. Límite cincuenta."* Tomorrow the same street is silent.

In all three the phone was locked in a pocket and the app had not been opened that day. That needs exactly four things: a position every second while the car moves; a way to be woken before the first radar when the phone was asleep; a decision that fires once, in the right direction, at a distance that depends on speed; and three delivery paths that need no internet (voice, the car screen, the phone screen).

---

## 1. Goals and non-goals

Goals
- Warn once per radar pass, early enough to be at the limit before the measuring point, only for radars ahead, never silently suppressed on data the feed is unsure about.
- Reach the driver through the car: speech over CarPlay or Bluetooth audio; a Live Activity on the CarPlay Dashboard (iOS 26) and the phone's Lock Screen; a Time Sensitive banner on the phone when no Live Activity runs.
- Work for days without opening the app, across lock, suspension, system termination and reboot (after first unlock).
- Spend nothing when not driving beyond what iOS already spends (significant-change plus one region); GPS only while driving.
- Nothing fails silently: an Estado screen measures every link of the chain, and a self-test that runs the real pipeline and can go red.
- Own the data: download, refresh and store the public feed in-app; a bundled snapshot so day one works offline.

Non-goals (v1)
- No CarPlay app (per-category entitlement; optional later, section 4.5).
- No Android build now (section 12 is its contract).
- No community reports, no live traffic, no speed-limit database, no radar detection of any kind.
- No Critical Alerts, no push-to-start Live Activities (both need what we do not have: an entitlement, a server).
- No spatial index, no database, no binary cache, no remote config, no feature flags. One setting: voice on/off.

---

## 2. Alert model

Everything in this section is in the package target `RadaresCore`, pure functions over a platform-neutral `Fix`. No Core Location types inside, so `swift test` runs on a Mac and the Android port is a translation.

### 2.1 Types

```swift
public struct Radar: Sendable, Codable, Identifiable, Hashable {
    public let id: String                 // feature.id, unique (4,452 of 4,452 today), stable per source
    public let kind: Kind                 // feed kind: fixed, section, stretch, mobileAnnounced, trailer, reported
    public let role: Role                 // derived: .point, .mobileCorridor, .averageSpeedSection
    public let start: Coordinate          // Point, or first vertex of the LineString
    public let end: Coordinate?           // last vertex of a LineString
    public let chordMetres: Double?       // sum of segment lengths of the LineString
    public let roadMetres: Double?        // |km_to - km_from| * 1000 when both are present
    public let name: String, road: String?, kmFrom: Double?, kmTo: Double?
    public let maxspeed: Int?             // null for 2,412 of 4,452 today
    public let bearing: Double?           // degrees 0..<360, monitored-traffic heading per OSM; nil when unknown
    public let bidirectional: Bool        // direction == "both"
    public let directionText: String?     // "ZARAGOZA" (DGT, Euskadi, Madrid...), spoken, never used to gate
    public let validFrom: Date?, validTo: Date?   // mobile_announced only (147 today, León 92 + Murcia 55)
    public let active: Bool               // 77 inactive today
    public let source: String, attribution: String, url: URL?, province: String?
}
public enum Kind: String, Codable, Sendable { case fixed, section, stretch, mobileAnnounced = "mobile_announced", trailer, reported }
public enum Role: Sendable { case point, mobileCorridor, averageSpeedSection }
public struct Fix: Sendable, Codable {
    public var coordinate: Coordinate, timestamp: Date
    public var speed: Double?             // m/s; nil when CLLocation.speed < 0 or speedAccuracy < 0
    public var course: Double?            // degrees; nil when course < 0 or courseAccuracy < 0
    public var horizontalAccuracy: Double
    public var isStationary: Bool
}
```

`FeedDecoder` derives the fields from `properties.direction`, which is three vocabularies in one string (measured today):
- a numeric string, 1,278 features, all `osm` (fixed 822, section 255, stretch 201). Eight are negative (`"-1"`, `"-10"`, `"-20"`, `"-40"`, `"-200"`): normalised `((x mod 360) + 360) mod 360` into `bearing`. OSM defines `direction` on a speed camera as "the way the speed camera faces" (https://wiki.openstreetmap.org/wiki/Tag:highway%3Dspeed_camera) and the talk page shows the community split between lens direction and monitored traffic (https://wiki.openstreetmap.org/wiki/Talk:Tag:highway%3Dspeed_camera). That is why section 2.4 never silently suppresses on it.
- `"both"`, 1,334 (1,331 `dgt_invive` stretches + 3 osm) → `bidirectional = true`.
- a place or street name, 453 (dgt 314, euskadi 97, madrid 33, osm 8, navarra 1; 138 distinct values, 106 of them DGT) → `directionText`, `bearing = nil`.
- `null`, 1,387 → nothing.

`role`: `kind == .stretch && source == "dgt_invive"` → `.mobileCorridor` (1,331, all `both`); any other `stretch` (dgt 47, osm 201, madrid 9, salamanca 4) → `.averageSpeedSection`; everything else `.point`. Section twins: 328 of the 359 `section` points sit exactly (same coordinates) on a stretch endpoint, 165 with id `<stretch>-from` at the first vertex and 163 with `<stretch>-to` at the last (252 stretches have a section at their first vertex; consecutive DGT stretches share endpoints). `FeedDecoder` merges every section point whose coordinate equals a stretch endpoint into that stretch, both ends, so one radar is warned once. The 31 that remain (sct 29, euskadi 2) stay `.point` and are spoken with the "radar de tramo" wording.

Alertable set, evaluated per fix: `active`, `kind != .reported` (OSM notes, unconfirmed; map only, grey), and for `mobileAnnounced` today's Europe/Madrid calendar day within `validFrom...validTo`. About 4,340 of 4,452 today.

### 2.2 Warn distance by speed

`WarnPolicy.warnDistance(speed:) = clamp(speed × 25 s, 300 m, 1,000 m)`, with `speed` = median of the last three valid speeds (one bad fix never moves the distance).

- 25 s horizon: 2 s to notice, 3 s to hear the sentence, 5.6 s to shed 20 km/h at a comfortable 1 m/s², the rest margin so the car is at the limit before the measuring point, not at it. The DGT publishes km-marker positions (about ±100 m); 25 s at 120 km/h is 833 m, which leaves 100 m of position error plus one 1 Hz fix (33 m) inside the margin.
- Floor 300 m: a 30 zone gives 208 m at 25 s; 300 m is 36 s there, still a warning, never "too late to matter".
- Cap 1,000 m: reached at 144 km/h. Beyond 1 km the warning is noise and the chance that the radar is on another road grows.
- Table: 50 km/h → 347 m, 80 → 556 m, 90 → 625 m, 100 → 694 m, 120 → 833 m.

Fix cadence is 1 Hz, so the firing error is one fix plus `horizontalAccuracy` (5 to 10 m with GPS). The HA route was 0.9 km late at 120 km/h because it waited for region entry; here the warning is computed from the fix (shortcoming H).

### 2.3 Approach test (`ApproachEvaluator`)

Course: `fix.course` when non-nil (Apple's only validity signal: a negative `course` or `courseAccuracy` means invalid, which `Fix` in 2.1 already applies: https://developer.apple.com/documentation/corelocation/cllocation/course, https://developer.apple.com/documentation/corelocation/cllocation/courseaccuracy) and `speed ≥ 3 m/s` (`Thresholds.courseMinSpeedMps`, our own threshold, not Apple's: below it the reported course wanders in practice; logged with every alert and tuned from real drives like `crossTrackMetres`); otherwise the bearing between the last two fixes at least 15 m apart; with no course at all nothing fires and the card shows the nearest radar as `cerca` (never speak with an unknown heading).

For each alertable radar whose nearest gate (`start`, or for lines the nearer endpoint) is within `warnDistance + 200 m` of the fix (hysteresis so the candidate set does not flicker), all of these must hold:
1. `ahead`: angle between the course and the bearing from the car to the gate ≤ 60°. A radar on a curve stays inside 60° until the warn distance; wider is beside or behind.
2. `closing`: distance decreased on each of the last two fixes by ≥ 1 m. A parallel road or an overpass plateaus or oscillates.
3. `inRange`: distance ≤ `warnDistance(speed)`.
4. `directionMatch`: if `bearing != nil && !bidirectional`, `|course − bearing| ≤ 90°` (mod 360). The half-plane only demotes the opposite flow (about 180° apart), never a radar on a curve.

Result `.full` when 1 to 4 hold; `.visual` when 1 to 3 hold and 4 fails. `.full` = speech + Live Activity alert + Time Sensitive notification (when no activity). `.visual` = a Live Activity row labelled `sentido contrario`, no voice, no notification. A missed warning costs a fine, a wrong "opposite" warning costs a glance; with contested direction data the app lowers the volume, it does not hide the radar.

No cross-track gate. On a curve of radius R the bearing to a gate s metres ahead deviates by about s/2R (tangent–chord theorem): 24° at s = 833 m, R = 1,000 m, and Spanish autovías are full of 1,000 to 2,500 m curves (Norma 3.1-IC's minimum for 120 km/h is about 700 m). A 100 m lateral limit would delay the voice on every one of them; the 60° cone passes them all. The price is a radar on a road 300 m beside the motorway at 800 m ahead (21° off, closing, in range): one false sentence, a glance. `crossTrackMetres` is logged on every alert so the number can be tuned from real drives.

Late: a radar first seen already inside `warnDistance − 100 m` (late wake-up, GPS warm-up) still fires, flagged `late: true`. Below 60 m and still closing: no voice (the sentence would end after the radar), the card shows it.

Passed: distance increasing on three consecutive fixes after the minimum, or distance < 30 m. The card shows `Radar superado` for 4 s.

Distances are haversine (one `cos` per candidate is nothing at this size), bearings via `atan2`. Candidates come from `RadarStore.candidates(near:within:on:)`, a linear scan over all entries with a precomputed lat/lon bounding box per radar (about 20 µs per fix on 4,452 entries). No spatial index; threshold to revisit: 50k features.

### 2.4 Direction and heading summary

| feed value | app behaviour |
|---|---|
| numeric (OSM) | heading gate ±90°; mismatch → `.visual`, logged `suppressedByDirection` |
| `both` | always `.full` |
| name (DGT "sentido ZARAGOZA") | always `.full`; the name is spoken and shown so the driver judges |
| null | always `.full` |
| future `bearing` + `direction_semantics: "travel"` (section 5.5) | hard suppression on mismatch; the only field that may hide a radar |

### 2.5 Stretches and sections (`StretchTracker`)

Geometry facts: 1,590 of 1,592 `stretch` LineStrings have exactly two vertices (the two Salamanca ones have 13); the chord between `km_from` and `km_to` is on median 0.91 of the road length (p10 0.71), median chord 10.7 km, p90 30 km, max 86.7 km. 22 stretches have `km_from ≥ km_to` and 214 have no km at all, so vertex order carries no direction. A stretch line is a chord, never the road.

Rules:
- A stretch is two gates (its endpoints) plus an inside state. The chord is only used to estimate progress.
- Entry: the approach test of 2.3 against the nearer endpoint, plus the course within ±60° of the bearing from that endpoint toward the other (going into the stretch, not out of it). For `.mobileCorridor` (all `both`) and for `.averageSpeedSection` without a bearing, either endpoint is an entry. An `.averageSpeedSection` with an OSM bearing follows 2.4 (`.visual` on mismatch). `directionText` is spoken when present.
- Spoken at entry: `.mobileCorridor` *"Tramo de radar móvil, {road}, {km} kilómetros."*; `.averageSpeedSection` *"Radar de tramo a {d} metros, {km} kilómetros. Límite {max}."* (limit only when known). Length = `roadMetres` when present, else `chordMetres`.
- Inside: the card shows `Tramo radar móvil · {road} · {km} km restantes` (remaining = chord minus the projection of the car onto the chord, labelled `aprox.`, updated every 500 m: Live Activity updates are budgeted, 4.2); for an average-speed section also `media {avgKmh} km/h` = path length since entry / elapsed time, the one number the driver wants there. No second voice prompt.
- Exit, whichever first: within 300 m of the far gate (voice *"Fin de tramo."*); straight-line distance from the entry gate > `max(roadMetres, chordMetres) + 1,000 m` (exact for a road: a car on the road is never farther from the entry than the road length; silent); 2× the traverse time expected at entry speed (silent); drive end.
- The pass state (2.6) is keyed by the stretch id, so a stretch is one pass.

### 2.6 Once per pass and cooldown (`PassTracker` + `PassLedger`)

Per radar id: `idle → armed (in the candidate band, ahead) → fired(level) → passed → cooldown → idle`.
- Cooldown ends when **both** `now − firedAt ≥ 10 min` and the car has been ≥ 2 km from the radar since firing. A roundabout, a missed exit, a petrol stop or a U-turn inside 10 minutes is the same pass; the commute back an hour later is a new pass. Shortcoming D.
- `PassLedger` (Codable) is persisted to `Application Support/Radares/passes.json` on fire, on pass and at drive end (never per fix), pruned at 24 h, ≤ 200 entries. A relaunch mid-drive, or a stop before the radar long enough to end the drive, cannot repeat the voice.
- Global pacing: at most one spoken alert per 8 s; a second radar that fires inside the gap gets `.visual` (the card shows both). Two radars firing in the same fix are one sentence: *"Radar fijo a 600 metros, y otro a 800."* `AVSpeechSynthesizer` queues utterances, so without this a city cluster talks for a minute.

### 2.7 What it says and shows (`Phrasing`)

Spoken (es-ES; en by phone locale), distance rounded to 50 m, limit only when `maxspeed` is set, direction text appended when present:
- fixed: *"Radar fijo a 800 metros. Límite 90."* / *"Radar fijo a 650 metros, sentido Zaragoza."*
- section (unpaired point): *"Radar de tramo a 600 metros."*
- average-speed section entry: *"Radar de tramo a 600 metros, 3 kilómetros. Límite 100."*
- mobile corridor entry: *"Tramo de radar móvil, N-232, diez kilómetros."* (the Z-40 has only a `dgt` average-speed section, `dgt-CVM_161274`, km 26.6 to 29.7)
- mobile_announced: *"Radar móvil anunciado a 350 metros. Límite 50."*
- trailer: *"Radar en remolque a 800 metros."*
- exits: *"Fin de tramo."*; passed: nothing spoken.
- Never: `reported`, inactive, expired, in cooldown, behind, `.visual`.

Live Activity content (`DriveAttributes.ContentState`, far under the 4 KB limit, https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): `phase` (watching, approaching, alert, passed, insideStretch, paused, degraded), `kindSymbol`, `title` ("Radar fijo"), `subtitle` (road + km, or name), `distanceMetres`, `limit`, `speedKmh`, `opposite: Bool`, `stretchRemainingMetres?`, `avgKmh?`, `note?` ("Datos de hace 3 días", "Abre la app"), `updatedAt`. Updates only at milestones: every phase change, and while a radar is ahead the distance crossings 1,000 / 750 / 500 / 250 / 100 m (`Thresholds.cardMilestonesM`), every 500 m inside a stretch (`stretchCardStepM`), else every 60 s. Never a fixed 50 m step: local `update` calls are allowed from the background but their delivery is budgeted and throttled by the system (4.2), and a refused update fails silently. The voice is the surface that carries the exact distance.

Notification: title `Radar fijo a 800 m`, body `A-2 km 202,3 · límite 90 km/h` (or `sentido Zaragoza`), `interruptionLevel = .timeSensitive`, `threadIdentifier = "radar"`, identifier `<radarId>#<passSeq>`; the previous radar's delivered notification is removed when the next fires or at pass, so the Lock Screen holds one.

---

## 3. Location strategy

`LocationCoordinator` (an `actor` in the app target, lane location) owns one state: `.idle`, `.probing`, `.driving`, `.paused(since:)`.

### 3.1 Four states

**`.idle` (not driving).** No GPS. Two independent, system-persisted wake-ups are armed:
- The parked fence: `CLMonitor("radares.wake")` with one `CLMonitor.CircularGeographicCondition(center: lastFix, radius: 400)` added as `add(condition, identifier: "parked", assuming: .satisfied)`, so the first `.unsatisfied` event is the exit (https://developer.apple.com/documentation/corelocation/clmonitor-2r51v/add(_:identifier:assuming:); WWDC23 10147: "If your assumption of the state is wrong, Core Location will give you the correct state once it is determined"). 400 m: Apple's testing figure for the cushion is about 200 m, and the device must then "remain at that minimum distance for at least 20 seconds" (https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/RegionMonitoring/RegionMonitoring.html), so the exit is reported, at best, 400 m + 200 m + 20 s of driving into the drive: about 0.9 km at 50 km/h, 1.1 km at 90, 1.3 km at 120, before the background launch and the GPS warm-up (up to 30 s, another 1 km at 120 km/h). That is the floor, not the expectation: Apple's current reference says a region report arrives "within 3 to 5 minutes on average, if not sooner" and "requires network connectivity" to be timely (https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:)), which at 120 km/h is 6 to 10 km, and "if Wi-Fi is disabled, region monitoring is significantly less accurate" (archived guide). So the wake lands between about 1 km and several kilometres into the drive; smaller radii make the cushion dominate, larger ones delay the wake further. "If an iOS app isn't running when a condition is satisfied, the system tries to launch it. When your app relaunches, it's your responsibility to recreate the monitor with the same identifier. Monitoring can only occur after the user unlocks the device after a reboot." (https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions). One of the 20 allowed conditions; the other 19 are unused in v1 (shortcoming E disappears: radars are not regions).
- Significant-change: one `CLLocationManager` (`slcManager`) with a delegate, `startMonitoringSignificantLocationChanges()` called at every launch and never stopped. "If you start this service and your app is subsequently terminated, the system automatically relaunches the app into the background if a new event arrives [...] Upon relaunch, you must still configure a location manager object and call this method to continue receiving location events." Granularity "500 meters or more", "not more frequently than once every five minutes" (https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()). Apple's authorization table: "Launches a terminated app automatically: Yes for significant location change, visits, and region monitoring services" (https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services).

Why two: CLMonitor has credible unanswered flakiness reports on iOS 18 (https://developer.apple.com/forums/thread/768373), and SLC is cell-based so it works where a fence needs Wi-Fi or GPS. They are co-equal wake-ups, not fence-first: SLC's 500 m / 5 min granularity and the fence's 3-to-5-minute average overlap, and whichever arrives first starts the probe. Both are re-armed at every launch; Estado shows which fired last, and `firstFixAfterWakeS` / `firstWarnAfterWakeM` in every `driveEnded` row are the measurement that decides the v1.1 radar rings (section 10, risk 7).

**`.probing` (woken, deciding).** Entered from any launch or resume that the user did not initiate. Nothing wraps it in `beginBackgroundTask`: what keeps the process alive is the `location` background mode plus an actively iterating `liveUpdates` stream; the recreated `CLServiceSession(.always)` only entitles the relaunch, it is not a keep-alive (WWDC24 10212: "Core Location does not take measures to keep apps running continuously when it has nothing to deliver to them"; Apple's authorization article: the app "continues to run in the background when location services are active; if location services aren't running, the normal suspension rules apply"). A woken process with no service running has only the pending event's "around 10 seconds" (archived guide), so **the stream starts first**: `bootstrap` starts `CLLocationUpdate.liveUpdates(.automotiveNavigation)` at once and runs the motion query concurrently; the gate decides whether the stream keeps iterating. Steps:
1. `MotionGate`, in parallel with step 2: `CMMotionActivityManager.queryActivityStarting(from: now − 180 s, to: now)`. Any sample with `automotive == true` and `confidence ≥ .medium` → `.driving` at once (the already-running stream continues as the drive). Apple: "A delay of up to several minutes in reported activities is expected" (https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager/queryactivitystarting(from:to:to:withhandler:)), hence the 3-minute window, and hence **the gate is positive-only**: no sample, stationary, walking, unknown or a delayed classification all fall through to step 2. A negative never suppresses the probe at drive start. Motion denied or not determined also falls through.
2. Speed probe: the `liveUpdates(.automotiveNavigation)` stream started in `bootstrap`, iterated for up to 60 s; three fixes with `speed ≥ 6 m/s` → `.driving`; `isStationary` or timeout → `.idle`. 6 m/s (21.6 km/h) is above running and below any road speed; a cyclist at 25 km/h gets warnings, which is harmless. 60 s because a cold fix can take 30 s and a car leaving a garage needs about 30 s to reach 20 km/h.
3. On `.idle`: move the parked fence to the newest fix (remove + add), break the loop. Cost of a walking wake: one launch, one Core Motion query and GPS until `isStationary` or the 60 s timeout, with or without Motion (the gate is positive-only, so it only shortens the driving case; said in onboarding).

**`.driving`.** Iterate `CLLocationUpdate.liveUpdates(.automotiveNavigation)` (https://developer.apple.com/documentation/corelocation/cllocationupdate/liveupdates(_:), configuration https://developer.apple.com/documentation/corelocation/cllocationupdate/liveconfiguration/automotivenavigation) in a `Task` owned by the coordinator; every update becomes a `Fix` and goes to `AlertEngine.ingest(_:)`; events go to `AlertDispatcher` (section 4). The drive state (`driving`, start time, last fix, `wakeSource`) is persisted to `UserDefaults` on every state change so a relaunch resumes the loop.

**`.paused(since:)`.** Entered when an update arrives with `isStationary == true` ("If Core Location stops delivering updates because the device is stationary, then it sets isStationary to true [...] the framework can suspend updates until the person starts moving, or their location becomes unknown": https://developer.apple.com/documentation/corelocation/cllocationupdate/isstationary), or after 120 s of fixes with `speed < 1 m/s`. The loop is **not** broken: WWDC23 10180 says "when the device becomes non-stationary, updates will automatically resume without any user interaction" and "as soon as updates are available [...] we will unsuspend your app" (https://nonstrict.eu/wwdcindex/wwdc2023/10180/). On entering `.paused`: re-arm the parked fence at the stationary position (so a termination while suspended still gets a wake-up), update the Live Activity to `phase: .paused` with `staleDate = now + 15 min`, log `drivePaused`. On the next update (the resume): if `now − since < 10 min` and `speed ≥ 3 m/s` → `.driving` again, same drive, same ledger; if ≥ 10 min → `.probing` (motion gate first, so a car that parked 12 minutes and left again is back in `.driving` on the first fix); if the motion gate reports walking with ≥ medium confidence and no automotive in the last 3 min → drive end. A timer is not needed and would not fire while suspended: the resume update is the clock. This replaces the earlier 180 s stop rule, which ended the drive in every motorway jam and then paid a fence exit (1 km to several kilometres, above) before warnings resumed.

Drive end (10 min paused, walking, `StopDriveIntent`, the "Avisos" switch): `AlertEngine.endDrive()`, flush `PassLedger`, Live Activity ended with `dismissalPolicy: .after(now + 5 min)`, fence re-armed, liveUpdates task cancelled, `driveEnded(fixes, maxGapSeconds, alerts, firstFixAfterWakeS, firstWarnAfterWakeM)` logged.

### 3.2 Sessions: what keeps Always alive

iOS 18 rule, WWDC24 10212 (https://nonstrict.eu/wwdcindex/wwdc2024/10212/): "Always authorization will only be effective when you hold one of these, and you can only start holding one when your app is in the foreground"; liveUpdates and `CLMonitor.events` "won't yield results when it is not in use, unless a session which was started in the foreground, or while another one was in effect asserts that continued interest"; and Core Location "doesn't keep track of these explicit and implicit sessions forever. Instead, it does so for only a few seconds after the app is launched again, whether that launch was due to Core Location API events, user interaction, or any other cause." Apple's guide: "Create the session while your app is in the foreground. If your app terminates, you must recreate the CLServiceSession immediately upon launch in the background." (https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background). DTS: "If you are using an explicit session, you will want to recreate the session asap upon launch in the background, otherwise your app will be assumed to no longer have interest in location updates, and you will need to start over when the app is in the foreground." (https://developer.apple.com/forums/thread/799094); the two common failures: invalidating the background activity session after the app was killed, and not rejoining it from a non-UI launch path (https://developer.apple.com/forums/thread/770063).

Therefore:
- `let alwaysSession = CLServiceSession(authorization: .always)` is created once in the foreground during onboarding and re-created as the first statement of every launch when the stored `wantsAlways` flag is set (https://developer.apple.com/documentation/corelocation/clservicesession-pt7n). It lives in `LocationCoordinator.shared`, a `let`, never invalidated except by the user's "Avisos" switch. The launch path has no UI dependency.
- `NSLocationRequireExplicitServiceSession` is not set: the implicit When-in-Use sessions from iterating `liveUpdates` and `CLMonitor.events` are wanted ("Core Location sets When in Use authorization implicitly when you process events from CLMonitor, CLLocationUpdate, or use a CLBackgroundActivitySession", same guide).
- **No `CLBackgroundActivitySession` under Always.** Apple: it "allows a when-in-use authorized app to receive location updates or monitoring events" (https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3); WWDC23 10180: "If you don't have an outstanding session, then you must start the new session from the foreground, but you can only rejoin an existing one from the background." It is used only in the degraded While-Using mode, created from the foreground, and rejoined at launch whenever the persisted drive state says one was outstanding; a launch path never invalidates it (DTS 770063's first failure).
- `Info.plist`: `UIBackgroundModes = [location, audio, fetch]`, `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription` (https://developer.apple.com/documentation/bundleresources/information-property-list/nslocationalwaysandwheninuseusagedescription), `NSMotionUsageDescription` (without it "your app crashes when you call this API": https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager), `NSSupportsLiveActivities = true`, `BGTaskSchedulerPermittedIdentifiers`.
- `CLServiceSession.diagnostics`, all eight flags logged: `alwaysAuthorizationDenied` (the goal was Always and only When In Use was granted, the degraded case this design cares about; WWDC24 10212: "or .alwaysAuthorizationDenied, when you have set a goal of Always authorization, but it was not granted"), `authorizationDenied` (location refused altogether), `authorizationDeniedGlobally`, `authorizationRestricted`, `fullAccuracyDenied` (the Precise Location case of 7 and risk 11), `insufficientlyInUse`, `authorizationRequestInProgress`, `serviceSessionRequired` (https://developer.apple.com/documentation/corelocation/clservicesession-pt7n/diagnostic) and the flags on every `CLLocationUpdate` and `CLMonitor.Event` (`conditionLimitExceeded`, `conditionUnsupported`, `persistenceUnavailable`, `authorizationDenied`, `accuracyLimited`, `serviceSessionRequired`: https://developer.apple.com/documentation/corelocation/clmonitor-2r51v/event) are logged and surfaced.

`CLLocationManager` is used only for authorization requests and significant-change. `allowsBackgroundLocationUpdates`, `pausesLocationUpdatesAutomatically`, `showsBackgroundLocationIndicator`, `activityType` and `distanceFilter` configure that manager's standard service, which is never started, so they are not set.

### 3.3 The launch path (shortcoming G)

SwiftUI `App` + `@UIApplicationDelegateAdaptor(AppDelegate.self)` (https://developer.apple.com/documentation/swiftui/uiapplicationdelegateadaptor; Apple's own live-updates article says a SwiftUI app needs the adaptor for background launches: https://developer.apple.com/documentation/corelocation/supporting-live-updates-in-swiftui-and-mac-catalyst-apps). `application(_:didFinishLaunchingWithOptions:)` does, synchronously, before returning:
1. `LocationCoordinator.shared.bootstrap(state: application.applicationState)`: recreate `alwaysSession` (if `wantsAlways`), create `slcManager` + delegate + `startMonitoringSignificantLocationChanges()`, create `CLMonitor("radares.wake")` and start the `for try await event in monitor.events` task, re-add the parked condition if `monitor.identifiers` lost it, and if the persisted drive state is `.driving`/`.paused` recreate the liveUpdates loop (and rejoin the `CLBackgroundActivitySession` in While-Using mode). `launchedInBackground = application.applicationState == .background`: launched in the background for any reason while idle → `.probing` immediately, stream first (3.1). The design does not branch on `UIApplication.LaunchOptionsKey.location`: it is deprecated as of iOS 26.0 ("Adopt CLLocationUpdate or CLMonitor, or use CLLocationManagerDelegate from CoreLocation to handle expected location events after scene connection", https://developer.apple.com/documentation/uikit/uiapplication/launchoptionskey/location), nothing documents it for a CLMonitor-triggered launch, and the target device runs iOS 26. The key is read only as an informational hint, under `#available` silencing, for the log. The event that woke us is also delivered through the monitor or SLC delegate, but the probe does not wait for it: the HA app lost exactly that event because its API object was not ready.
2. `BGTaskScheduler.shared.register(forTaskWithIdentifier: "io.github.geiserx.radares.refresh")` (must be registered before launch finishes).
3. `UNUserNotificationCenter.current().delegate = Notifier.shared`.
4. `RadarStore.shared.loadIfNeeded()` on a utility task (section 5).
5. `DriveActivityController.shared.reattach()`: adopt `Activity<DriveAttributes>.activities.first` if the persisted drive is alive, end anything older.
6. Log `launch(reason:, state)`. The reason is derived from the first thing that arrives after launch (`monitorEvent`, the SLC delegate callback, a liveUpdate, the BG task, an intent, a scene) rather than from a launch option; until something arrives it is `unknown`.

Nothing here touches a window.

### 3.4 Each mechanism under the four conditions

| Mechanism | App terminated by iOS | Phone locked | No network | "While Using" only |
|---|---|---|---|---|
| Parked fence (CLMonitor) | iOS relaunches the app for the exit (reported 1 km to several kilometres into the drive, speed- and network-dependent, 3.1); the monitor is recreated by name in the first second | Works (needs first unlock after reboot) | Works for the exit itself; "the region monitoring service requires network connectivity" to report in a timely manner, "3 to 5 minutes on average" with it (https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:)) | Not delivered while not running: "the system doesn't launch an app with When in Use authorization to deliver new updates" |
| Significant-change | Relaunched into the background; `startMonitoringSignificantLocationChanges()` called again at launch | Works | Works (cell); "much more likely to deliver notifications in a timely manner" with network | Same as above |
| `liveUpdates` while driving | Core Location "will recover your app as soon as location updates are available by launching it in the background" (WWDC23 10180); `bootstrap` restarts the loop from the persisted drive state | Works | Works (GPS needs no network) | Works for a drive begun in the foreground with a `CLBackgroundActivitySession`; while that session is outstanding Core Location unsuspends and relaunches the app (WWDC23 10180, WWDC24 10212, DTS 770063) and `bootstrap` must rejoin it, never invalidate it from a launch path; after the drive ends and the session is invalidated nothing wakes the app |
| `CLServiceSession(.always)` | Recreated within the first second of launch | n/a | n/a | Diagnostics show `alwaysAuthorizationDenied` (`fullAccuracyDenied` for reduced accuracy, `authorizationRestricted` under restrictions); Estado goes red with a Settings button |
| Motion gate | Historical query works after relaunch (7-day store) | Works | Works | Works |

Degraded While-Using mode: the user opens the app (or taps the "Conducir" control, whose intent has `openAppWhenRun = true` in this mode); the coordinator creates a `CLBackgroundActivitySession` (the blue pill) and starts `.driving`. After the drive ends and the session is invalidated nothing wakes the app again; Estado says so in red: "Sin permiso Siempre: abre la app antes de conducir", and the Live Activity note says "Avisos solo con la app abierta antes de conducir". The facts allow one more product choice, not taken in v1: keeping that session outstanding permanently (blue pill always on) would give While-Using users the fence and SLC wake-ups too; it is listed in VERIFY.md as a measurement, not a feature.

Reboot: no location events before first unlock; after it, SLC and the fence relaunch us; the store is readable (5.3); `bootstrap` re-takes the session. Days without opening the app: launch → re-take session → probe → drive → pause → re-arm fence → suspended or terminated → launch. Every link is system-persisted or recreated in `bootstrap`; Estado's "último arranque en segundo plano" timestamp is the proof it is intact.

### 3.5 Battery

Idle: SLC (shares the cell radio) + one region (system-monitored) + zero timers. Walking wakes with the motion gate: a launch per ~500 m, no GPS. Driving: GPS at 1 Hz like any navigation app; engine cost about 20 µs per fix; Live Activity updates only near a radar; speech only on `.full`. `kCLLocationAccuracyBestForNavigation` is not requested ("use this level of accuracy only while the device is plugged in": https://developer.apple.com/documentation/corelocation/kcllocationaccuracybestfornavigation). Estado shows the last 7 days' wake-ups and drive minutes so a runaway (a bus commuter getting 2 h of GPS a day) is visible; a "Pausar hoy" switch is the one-line answer if it happens.

---

## 4. Surfaces

Every surface reads the same `AlertEvent` stream through `AlertDispatcher`, so a surface that is unavailable (no Live Activity, notifications denied, voice off) changes nothing upstream, and the log records which sinks fired on each alert.

### 4.1 Speech (`SpeechAnnouncer`)

`AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])`; `setActive(true)` right before `synthesizer.speak(utterance)`; `setActive(false, options: .notifyOthersOnDeactivation)` in `speechSynthesizer(_:didFinish:)`.
- `voicePrompt` "allows for different routing behaviors when your app connects to certain audio devices, such as CarPlay. An example of an app that uses this mode is a turn-by-turn navigation app" (https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voiceprompt).
- `interruptSpokenAudioAndMixWithOthers` pauses podcasts and audiobooks and resumes them after; `duckOthers` lowers music (https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/interruptspokenaudioandmixwithothers, https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/duckothers). `playback` continues "with the Silent switch set to silent or when the screen locks" (https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback).
- The `audio` background mode is required: `AVAudioSession.ErrorCode.cannotStartPlaying` "can also occur if the app is in the background and using a category that doesn't allow background audio" (https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotstartplaying). The review note says why (section 8).
- Voice: `AVSpeechSynthesisVoice(language: "es-ES")`, enhanced if installed, compact otherwise (always on the device). The synthesizer is retained by the announcer ("you need to manually retain it until speech concludes": https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer). One utterance at a time; a `Fin de tramo` queued behind a radar warning is dropped.
- Per utterance the log records the route (`currentRoute.outputs.first?.portType`: `.carAudio`, `.bluetoothA2DP`, `.builtInSpeaker`), the `setActive` result and `didFinish`. A `setActive` error is a red Estado row, never a silent miss.
- Terminated: nothing speaks (nothing runs; a drive guarantees a running app). Locked, drive begun in the foreground: works. Locked, drive detected purely in the background (process launched by CLMonitor or SLC, never foregrounded): **unproven until measured.** Apple's `cannotStartPlaying` page supports per-utterance activation under the `audio` mode, but two DTS answers say the opposite in general terms ("In general, apps can't start playing audio in the background [...] There are some circumstances where this is possible, for example, navigation apps, but those are very tightly controlled", https://developer.apple.com/forums/thread/77937; "It is not possible to start an AV session if the app is in the background. And certainly not if it is not running", https://developer.apple.com/forums/thread/759816), and neither thread is the location-kept-alive case. So VERIFY.md has a background-launch speech test that can go red: with the app terminated, trigger the drive from the CarPlay automation or a simulated wake, drive past a radar, and assert a `speech(route:, setActiveError: nil, finished: true, launchContext: background)` row. If `setActive` fails from a cold background launch, the fallback is already designed: activate the session once at the first fix of the drive and keep it active with `.mixWithOthers`, toggling `.duckOthers` only around utterances, instead of per utterance. The outcome is recorded in VERIFY.md either way. No network: works. While Using: works during a foreground-started drive.

### 4.2 Live Activity (`DriveActivityController`, `DriveAttributes`)

Platform fact: `Activity.request` cannot run in the background "unless you adopt App Intents and start the Live Activity using a LiveActivityIntent" (https://developer.apple.com/documentation/activitykit/activity/request(attributes:content:pushtype:)); the error is `ActivityAuthorizationError.visibility` (https://developer.apple.com/documentation/activitykit/activityauthorizationerror/visibility). DTS: "It is not possible to programmatically initiate a Live Activity from a background execution context, such as a CLLocationManager wakeup, using local APIs." (https://developer.apple.com/forums/thread/818467).

So the Live Activity starts in one of three ways:
1. `StartDriveIntent: LiveActivityIntent` ("the system launches your app process without opening the app, performs the intent, and starts the Live Activity": https://developer.apple.com/documentation/appintents/liveactivityintent), exposed as a `ControlWidgetButton` "Conducir" for Control Center, the Lock Screen and the Action button (https://developer.apple.com/documentation/widgetkit/controlwidgetbutton), and through `AppShortcutsProvider` so it appears in Atajos and Siri without setup (https://developer.apple.com/documentation/appintents/appshortcutsprovider). A personal automation "CarPlay → Conecta → Ejecutar inmediatamente → Iniciar aviso de radares" runs it with no confirmation: CarPlay is in Apple's list of automations that run automatically (https://support.apple.com/es-es/guide/shortcuts/apd602971e63/ios) and DTS recommends exactly this, "there is no direct, programmatic way within the iOS SDK to automatically wake or launch your app specifically when the iPhone connects to CarPlay" (https://developer.apple.com/forums/thread/820693). The intent puts the coordinator straight into `.driving` (Always: location starts from the intent-launched process because the session is re-taken at launch; While Using: it cannot, and the card says `Abre la app`).
2. The app in the foreground (opened at drive start, or opened mid-drive: `RootView.onAppear` requests it when `.driving`).
3. "Probar aviso" in the foreground (section 6).

A drive detected purely in the background has speech and the notification; Estado shows "Pantalla del coche no iniciada en el último viaje" with the automation recipe.

Updates: `activity.update(ActivityContent(state:, staleDate: now + 120 s))` may be called from the background (https://developer.apple.com/documentation/activitykit/activity/update(_:)), but delivery is budgeted: an Apple Frameworks Engineer, "We purposely discourage and throttle update frequencies similar to a now playing experience in Live Activities [...] usually priority and budget matter the most here" and "your LA is actually tied to the system (Lock Screen, Springboard) so those processes also have a say in whether an update takes place"; "APNs with frequent updates enabled is the supported way to update a Live Activity that needs a lot of updates" (https://developer.apple.com/forums/thread/748569). A refused update fails silently (no error; only `liveactivitiesd` logs it in Console.app) and `NSSupportsLiveActivitiesFrequentUpdates` applies to push only. Apple publishes no local-update limit, hence the milestone cadence of 2.7 (phase changes, 1,000 / 750 / 500 / 250 / 100 m, 500 m steps inside a stretch, else 60 s). After every `update` the controller re-reads `activity.content` and logs `activityUpdated(dropped: Bool)`, so a throttled update is a visible row, not a silent miss; the real-device drive watches Console.app for `liveactivitiesd` budget lines and records the observed cadence in VERIFY.md. `staleDate` shows a dead app as stale within 2 minutes (15 min while `.paused`). On `.full` the update carries `AlertConfiguration(title: "Radar fijo a 800 m", body: "A-2 km 202,3 · límite 90", sound: .named("radar-tick.caf"))`, a 150 ms tick so it does not stack with the voice (the options are `.default` and `.named`: https://developer.apple.com/documentation/activitykit/alertconfiguration/alertsound); the alert lights the screen and expands the Dynamic Island (HIG: "Live Activity alerts light up the screen and by default play the notification sound [...] Alerts also show the expanded presentation in the Dynamic Island", https://developer.apple.com/design/human-interface-guidelines/live-activities; the `update(_:alertConfiguration:timestamp:)` page itself does not say it). Users can "control alerts by enabling a focus mode" (WWDC25 216), so this alert is Focus-controlled too and is one of the Driving Focus rows in VERIFY.md (4.3). When an activity is running the local notification of 4.3 is skipped (HIG: "don't use push notifications alongside Live Activities for the same updates", https://developer.apple.com/design/human-interface-guidelines/live-activities). End with `end(content, dismissalPolicy: .after(now + 5 min))`; the lingering applies to the Lock Screen only (HIG: "When a Live Activity ends, the system immediately removes it from the Dynamic Island and in CarPlay"). 8-hour cap, 12 h on the Lock Screen (https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities): a drive over 8 h loses the card; speech and notifications continue.

CarPlay, iOS 26: "CarPlay uses the activity family small size class to display your Live Activity. If you don't yet implement activity family small, CarPlay will fall back to showing the compact leading and trailing views" and "if CarPlay Dashboard is not visible, CarPlay ensures drivers don't miss an important alert by showing it as a notification at the bottom of the display"; "Live Activities in CarPlay are non-interactive" (WWDC25 216, https://developer.apple.com/videos/play/wwdc2025/216/, transcript https://nonstrict.eu/wwdcindex/wwdc2025/216/). The CarPlay App Programming Guide (2026-06-08, "Live Activities in CarPlay") says the same: "To enable your Live Activity in CarPlay, support the small activity family. This is the same size used for Live Activities in the Apple Watch Smart Stack [...] If you don't support the small activity family, CarPlay will show the compact leading and compact trailing views from your Dynamic Island configuration instead" (https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf), and the HIG's CarPlay section asks to "declare support for a [...] supplemental activity family". HIG sizes 240×78, 240×100 and 170×78 pt, Smart Display Zoom presets 1920×720, 900×1200 and 800×480, and a Night Mode red tint (https://developer.apple.com/design/human-interface-guidelines/live-activities). Implementation: `.supplementalActivityFamilies([.small])` on the `ActivityConfiguration` (https://developer.apple.com/documentation/swiftui/widgetconfiguration/supplementalactivityfamilies(_:)) and an `@Environment(\.activityFamily)` switch rendering: kind symbol, "Radar fijo", distance in large digits, limit badge, no buttons. No CarPlay entitlement. Terminated: the activity stays until stale, then ended or reattached at the next launch. Locked: it is the Lock Screen. No network: n/a. While Using: unchanged.

### 4.3 Time Sensitive local notification (`Notifier`)

`UNMutableNotificationContent.interruptionLevel = .timeSensitive`: "The system presents the notification immediately, lights up the screen, can play a sound, and breaks through system notification controls [...] such as Notification Summary and Focus" (https://developer.apple.com/documentation/usernotifications/unnotificationinterruptionlevel/timesensitive). Capability "Time Sensitive Notifications" (entitlement `com.apple.developer.usernotifications.time-sensitive`, WWDC21 10091 https://developer.apple.com/videos/play/wwdc2021/10091/). Authorization `requestAuthorization(options: [.alert, .sound])`: the `.timeSensitive` option is deprecated (availability iOS 15.0 to 15.0: https://developer.apple.com/documentation/usernotifications/unauthorizationoptions). Posted only when `DriveActivityController.current == nil`; `sound` nil when voice is on (the voice is the sound), `.default` when the driver turned voice off. Estado reads `UNNotificationSettings.authorizationStatus` and `timeSensitiveSetting` (https://developer.apple.com/documentation/usernotifications/unnotificationsettings/timesensitivesetting). It passes the Focus modes that allow Time Sensitive notifications; **Driving Focus may silence it.** No Apple page says Time Sensitive passes Driving Focus: Apple's Driving Focus page documents only people (calls, Auto-Reply) as what comes through (https://support.apple.com/guide/iphone/stay-focused-while-driving-iphae754533b/ios), Driving has no Apps section where the "Time Sensitive Notifications" toggle of other Focuses lives, and hands-on reports from users (not Apple staff) say "app notifications, even time sensitive ones, will have to wait until you exit driving focus mode" (https://discussions.apple.com/thread/256018482). So the notification is the surface for the no-Live-Activity, no-Focus case; speech is the only Focus-proof surface (audio sessions are not Focus-filtered), and onboarding says that with Driving Focus the warning arrives by voice. "Time Sensitive through a Driving Focus" and "Live Activity alert through a Driving Focus" are explicit pass/fail rows in VERIFY.md. Not shown on CarPlay (no entitlement; 4.5).

### 4.4 In-app map and status

SwiftUI `Map` with the radars within 5 km (points by kind, polylines for stretches, grey `reported` labelled "sin confirmar"), the user's position, a "next radar" card fed by `AlertEngine.snapshot`, the Estado strip above the map, and "Últimos avisos" (24 h: time, kind, road, distance, speed, level, sinks). Settings: voice on/off, "Avisos" master switch, "Pausar hoy", export log. Sources screen with each `attribution` verbatim and its `url`.

### 4.5 CarPlay driving-task app (optional, later, never the only path)

Entitlement `com.apple.developer.carplay-driving-task` requested by the maintainer at https://developer.apple.com/contact/carplay (https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements); then a `CPTemplateApplicationScene` with a `CPInformationTemplate` for the next radar. Notifications on the car screen need, per the CarPlay App Programming Guide (https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf): the `.carPlay` option in `requestAuthorization` (added to section 7's request once the entitlement exists; today it is `[.alert, .sound]`), `UNNotificationCategoryOptions.allowInCarPlay` on the category ("Apps must be approved for CarPlay overall"), iOS 18.4 or later ("Starting in iOS 18.4, notifications are also supported in CarPlay driving task apps"; an Apple Frameworks Engineer confirms the floor in https://developer.apple.com/forums/thread/795990, so an 18.0 to 18.3 device never shows them), and, per Apple on the same thread, "Notifications on CarPlay requires the app icon present on the CarPlay Home Screen", with a developer still failing on 18.6. The `CPInformationTemplate` is a static "next radar" screen (kind, road, km, limit) refreshed no more than every 10 s: driving-task guideline 4, "Do not periodically refresh data items in the CarPlay UI more than once every 10 seconds", rules out a live countdown there. The request text and these rules live in `docs/CARPLAY.md`.

---

## 5. Data

### 5.1 Feed download (`FeedClient`, core)

Source: `https://geiserx.github.io/radares-anunciados-ha/feed.geojson` only. `status.json` is not used: attribution and url are properties on every feature and nothing in the driver's picture reads per-source status.

A plain `URLSession` GET with `If-None-Match: <etag>`, 15 s timeout, `allowsCellularAccess = true` (about 160 KB gzipped; measured 0.24 to 0.49 s for a full body, 0 bytes on a 304). No background `URLSession`, no `handleEventsForBackgroundURLSession`: the whole transfer fits inside a `BGAppRefreshTask`'s "30 seconds of run time" (WWDC19 707, https://nonstrict.eu/wwdcindex/wwdc2019/707/) and inside a running drive. 304 → `checkedAt` moves; 200 → `FeedValidator` (parses, `type == FeatureCollection`, `features.count ≥ 2,000` against 4,452 today, at least one `fixed`, every feature has `id`, `kind`, `geometry`), then `FileStore.replace` (atomic rename, previous file kept as `feed.geojson.bak`), `RadarStore.reload()`, log `feedUpdated(count, etag)`. A failed validation keeps the old file and logs a red event: a half-empty publish never replaces a good file.

### 5.2 Refresh schedule (`FeedRefreshPolicy`, pure, core)

- `BGAppRefreshTaskRequest("io.github.geiserx.radares.refresh")`, `earliestBeginDate = now + 6 h`, resubmitted at the end of each run; requires the `fetch` background mode (https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask). 6 h matches the publisher's cadence.
- On every foreground: refresh if `fetchedAt` older than 6 h.
- At every drive start: refresh if older than 24 h (the app is running; the download never blocks the alert path, the engine keeps the old file until the swap).
- Manual "Actualizar ahora".
- Background App Refresh off or Low Power Mode: the BG task does not run ("Background App Refresh is disabled automatically when a device is operating in low-power mode": https://developer.apple.com/documentation/uikit/uiapplication/backgroundrefreshstatus); Estado says so.
- Staleness never disables alerts: fixed radars move rarely and `mobileAnnounced` entries expire by `validTo` on their own. Estado: amber at 2 days, red at 7.

### 5.3 Storage and file protection (shortcoming C)

`Application Support/Radares/`: `feed.geojson`, `feed.geojson.bak`, `feed.meta.json` (`etag`, `lastModified`, `fetchedAt`, `checkedAt`, `featureCount`, `countsByKind`, `lastError`), `passes.json`, `events.jsonl`. All written with `Data.write(to:options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])` and the directory attribute `.protectionKey = .completeUntilFirstUserAuthentication`: "After the user unlocks the device for the first time, your app can access the file and continue to access it even if the user subsequently locks the device." (https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication). Not `.none`: nothing needs the file before first unlock because iOS delivers no location events before first unlock either. `FileStore` reads the attribute back after each feed swap and logs `protectionVerified(ok)`: the one check that proves C is closed on the device. `isExcludedFromBackup = true` on the folder (re-downloadable). No SQLite, no app group container for the feed, no file held open across suspension.

Bundled snapshot `App/Sources/Resources/feed-snapshot.geojson`, copied into the folder on first launch when no feed exists, so the first drive after install works offline; `scripts/update-snapshot.sh` refreshes it; `release.yml` fails when the snapshot is older than 30 days (a gate that can go red).

### 5.4 Decoding, memory, lookup

`FeedDecoder` parses GeoJSON with `JSONDecoder` into `[Radar]` (value types, about 4,452 × ~120 bytes ≈ 0.5 MB resident; the two 13-vertex lines keep their arrays). Decoding 2.9 MB is expected at 80 to 200 ms on an A15-class core; the perf test asserts < 500 ms. Transient JSON memory is tens of MB and is freed before the probe starts; backgrounded apps should stay under 50 MB (WWDC20 10078, https://developer.apple.com/videos/play/wwdc2020/10078/). No binary cache in v1; it is the upgrade path if the TestFlight measurement says otherwise.

Lookup: `RadarStore.candidates(near:within:on:)` is a linear scan with a precomputed lat/lon bounding box per radar (points: the point; lines: their bbox), then the exact distance for survivors. Densest 0.1° 3×3 neighbourhood today: 280 features.

### 5.5 Feed contract (platform-neutral, `docs/SPEC.md`)

What the app reads today: `FeatureCollection` of `Feature { id, geometry: Point|LineString, properties: { kind, name, source, active, maxspeed, direction, province, url, attribution, radius_m?, valid_from?, valid_to?, reported?, road?, km_from?, km_to? } }`. Unknown kinds and properties are ignored. `radius_m` is an HA zone artefact, unused.

Requests for the feed repo (`radares-anunciados-ha`), none blocking, all honoured when present and ignored when absent:
1. `bearing` (degrees, heading of the monitored traffic) where the source allows it (OSM `direction` mapped under the community reading; DGT "sentido X" resolved from the road geometry the feed repo already has), plus `direction_semantics: "travel"` so clients may gate with confidence. Until then single-direction DGT radars warn both ways with the direction spoken.
2. Stretch geometry following the road where a source has it (OSM ways), or `geometry_is_chord: true` otherwise.
3. An explicit `section_of: <stretch id>` on `section` points instead of the `-from`/`-to` suffix convention.
4. `generated` (ISO date) at the top level of `feed.geojson` (today freshness comes from `Last-Modified`).

---

## 6. Monitoring health (shortcoming F, and "nothing silently broken")

`EventLog` (core): append-only JSONL in `events.jsonl`, one line per event `{t, kind, data}`, rotated at 2,000 lines (about 300 KB), exported with the share sheet. Kinds: `launch(reason, state)`, `sessionTaken`, `wakeup(source: monitor|slc, flags)`, `probe(result, motion, maxSpeed, seconds)`, `driveStarted(wakeSource)`, `fix` (one every 60 s, not every fix), `alert(id, level, distance, speed, late, crossTrackMetres, suppressedByDirection, sinks)`, `passed`, `stretchEntered/Exited(reason)`, `drivePaused/Resumed`, `driveEnded(fixes, maxGapSeconds, alerts, firstFixAfterWakeS, firstWarnAfterWakeM)`, `feedChecked/Updated/Failed`, `bgTaskRan`, `notificationPosted(error?)`, `activityStarted/Failed(error)`, `activityUpdated(dropped)` (content re-read after each update), `speech(route, setActiveError?, finished, launchContext: foreground|background)`, `monitorEvent(identifier, state, flags)`, `protectionVerified(ok)`, `userTerminated` (from `applicationWillTerminate`). No user coordinates beyond the alert rows, which the user can wipe.

`healthReport(_ inputs: HealthInputs) -> [HealthItem(status: ok|warn|fail, title, detail, action)]` is a pure function in core; `HealthMonitor` (app) collects the inputs. Rows:

| Row | Source | Red when |
|---|---|---|
| Ubicación | `CLLocationManager.authorizationStatus`, `accuracyAuthorization` | not `.authorizedAlways` (amber `.authorizedWhenInUse`), or reduced accuracy (then "your app can't use region monitoring", https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization) |
| Sesión Siempre | `CLServiceSession.diagnostics` (all eight flags logged) | `alwaysAuthorizationDenied` ("Permiso Siempre no concedido"), `fullAccuracyDenied` (Precise off), `authorizationRestricted`, `authorizationDenied`, `authorizationDeniedGlobally`, `insufficientlyInUse` |
| Arranques solos | log: `launch(reason: location|intent)` vs `driveStarted` in 7 days | amber when drives happened in the last 7 days and none began from a background launch or an intent ("iOS no ha arrancado la app sola"); red when the last event is `userTerminated` ("Última sesión cerrada por ti: no cierres la app desde el selector") |
| Valla de aparcamiento | last `monitorEvent("parked")` flags | `conditionLimitExceeded`, `persistenceUnavailable`, `authorizationDenied`; amber if the identifier is missing after re-add |
| Cambio significativo | started flag + last delivery | no delivery in 14 days while drives happened |
| Datos | `feed.meta.json` | `fetchedAt` > 7 d (amber > 2 d), count < 2,000, or last 3 attempts failed |
| Actualización en segundo plano | `backgroundRefreshStatus`, pending requests, last `bgTaskRan` | `.denied`; amber `.restricted` or no run in 3 days or Low Power Mode |
| Notificaciones | `UNNotificationSettings` | `authorizationStatus != .authorized`; amber `timeSensitiveSetting == .disabled` |
| Pantalla del coche | `ActivityAuthorizationInfo().areActivitiesEnabled`; last `activityStarted` vs `driveStarted` | disabled; amber "Automatización no probada" until the first intent-started drive is logged |
| Movimiento | `CMMotionActivityManager.authorizationStatus()` | amber if denied (probes cost GPS) |
| Voz | last `speech` | `setActive` threw, or es-ES voice missing |
| Archivos | `protectionVerified` | attribute read-back ≠ `completeUntilFirstUserAuthentication` |
| Último viaje | `driveEnded` | amber if `maxGapSeconds > 10` while moving (iOS throttled or suspended us) or any `late` alert |

"Probar aviso" (a check that can fail): injects a synthetic `fixed` target 600 m ahead on the current heading (due north when stopped) through the real `AlertEngine` and the real `AlertDispatcher`: the driver hears the sentence, sees the Live Activity (started for the test, the app is in the foreground) and, with the activity dismissed, the Time Sensitive notification; the log shows each sink's outcome. An engine or phrasing regression fails this test for the same reason a real warning would. It runs in the foreground, so it cannot fail for the background-audio reason of 4.1; that case has its own device test in VERIFY.md.

Red while closed: a plain (`.active` level, not Time Sensitive) local notification at most once per 24 h when the report is red and the app is not open ("Radares: los datos tienen 8 días, abre la app"), posted from a wake-up or a BG refresh run. A driver trusting a dead app is the failure the HA route taught.

Shortcomings → mechanisms:

| | Shortcoming | Mechanism |
|---|---|---|
| A | zones stored only on screen, bursts dropped | own feed download at foreground, BG refresh every 6 h, drive start; validated atomic replace (5.1, 5.2) |
| B | Android refetch only on restart | same policy in `docs/SPEC.md`; WorkManager periodic on Android (12) |
| C | store unreadable while locked | `completeUntilFirstUserAuthentication` on every file, read back and shown (5.3) |
| D | re-registration repeats alerts | no radar regions; `PassTracker` once per pass, persisted ledger, 10 min and 2 km (2.6) |
| E | first 100 alphabetically, 20-region cap | candidates by distance from the fix every second; the only region is the parked fence (3.1) |
| F | registration result unchecked | every `CLMonitor.Event` flag, `monitor.identifiers`, session diagnostics, SLC deliveries, sink outcomes on Estado (6) |
| G | relaunch event dropped | `bootstrap` in `didFinishLaunching` re-takes the session and starts the stream before any UI; the wake-up event itself is not needed (3.3) |
| H | region entry 0.9 km late at 120 km/h | the warning is computed from 1 Hz fixes at the speed-scaled distance; regions only wake the app (2.2, 3.1) |
| I | circles warn both ways, stretches as circles | heading cone, bearing gate with `.visual` demotion, direction text spoken, stretch gates and inside state (2.3 to 2.5) |
| J | alerts via HA push, needed internet | speech, Live Activity, local notification all on-device; network only for the feed (4) |

---

## 7. Permissions and onboarding

Four screens, each explaining before it asks ("make authorization requests only when someone engages a part of your app that requires that data": https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services), all skippable, each re-openable from Estado. Spanish UI, English strings too (`Localizable.xcstrings`).

1. **Ubicación.** "Avisa de los radares anunciados por la DGT, las listas semanales de policías locales publicadas en prensa, y OpenStreetMap. Solo posiciones anunciadas, nunca detectadas. Sin cuenta, sin servidor, sin anuncios. No cierres la app desde el selector." `requestWhenInUseAuthorization()` first; once granted, `requestAlwaysAuthorization()`. Apple, verified today: "If the user grants When In Use permission after your app calls requestWhenInUseAuthorization(), then calling requestAlwaysAuthorization() immediately prompts the user to request Always permission" with the options "Keep Only While Using" and "Change to Always Allow"; "If the user responded to requestWhenInUseAuthorization() with Allow Once, then Core Location ignores further calls to requestAlwaysAuthorization()"; "Core Location limits calls to requestAlwaysAuthorization(). After your app calls this method, further calls have no effect." (https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization()). Provisional Always and the deferred second prompt belong only to the direct-from-`notDetermined` path, which this app does not use; there is nothing provisional to detect. Then `CLServiceSession(authorization: .always)` is created here, in the foreground, and `wantsAlways = true`. Precise Location must be on; the screen says so. Purpose strings: When In Use "Para calcular la distancia y el sentido hacia los radares anunciados."; Always "Para avisarte en el coche sin abrir la app: se despierta al moverse y solo usa el GPS mientras conduces. La ubicación nunca sale del teléfono."
2. **Avisos.** `requestAuthorization(options: [.alert, .sound])` with the Time Sensitive explanation (it passes most Focus modes; with Driving Focus the warning arrives by voice, 4.3), and a second button for Movimiento: the first `queryActivityStarting` shows the Core Motion prompt ("the prompt that the user must accept the first time the system asks the user to access motion data": https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager), so it must happen here in the foreground, not lazily in a background probe. `NSMotionUsageDescription`: "Para saber si vas en coche y no gastar batería cuando caminas." Skip allowed.
3. **En el coche.** The car card (Live Activity, iOS 26 CarPlay) and the three starters: the Shortcuts automation (Atajos → Automatización → + → CarPlay → Conecta → Ejecutar inmediatamente → acción "Iniciar aviso de radares"), the Control Center control / Action button, "o simplemente abre la app". A "Probar" button starts the Live Activity in the foreground so the user sees it on the Lock Screen at once.
4. **Estado.** The health screen, also the first tab. Onboarding is complete when location is Always and the feed is loaded; everything else may stay amber.

Every later revocation flips its Estado row with a button to `UIApplication.openSettingsURLString`, never a modal nag. The "Avisos" switch invalidates the session, stops SLC and removes the fence: the way out of every state the app adds.

---

## 8. App Review and legal

- Background modes `location` + `audio` + `fetch`, Guideline 2.5.4 ("Multitasking apps may only use background services for their intended purposes: VoIP, audio playback, location, task completion, local notifications, etc.", https://developer.apple.com/app-store/review/guidelines/). Review note (Spanish and English): "Radares Anunciados avisa al conductor antes de los radares cuya posición publican organismos públicos españoles (DGT, policías autonómicas y municipales) y OpenStreetMap. La ubicación en segundo plano detecta que el teléfono va en un coche en marcha y mide la distancia y el rumbo al siguiente radar publicado; el audio en segundo plano pronuncia el aviso por el audio del coche, como una indicación de navegación; fetch actualiza cada 6 horas un archivo GeoJSON público. Sin cuenta, sin servidor propio, sin compras, sin anuncios, sin seguimiento: la única conexión es un GET a geiserx.github.io sin identificadores. Usa solo posiciones anunciadas de antemano: las que publica la DGT, las listas semanales de las policías locales de León y Murcia tal como aparecen en la prensa local, y las de OpenStreetMap; no detecta señales de radar." DTS warns against using Core Motion or Core Location "to wake your app in the background when the user starts moving in a vehicle" (https://developer.apple.com/forums/thread/820693); the note states that the wake-ups are Apple's own significant-change and region services used as documented and that continuous location runs only while the phone moves at road speed.
- Guideline 1.4.4 ("Apps may only display DUI checkpoints that are published by law enforcement agencies", "never encourage... excessive speed"): the rule is about DUI checkpoints, which the feed does not carry; the note does not claim "only official publications" because the feed's own attribution strings say otherwise. `leon` (92 features): "Redacción ILEÓN, obtenido de ILEÓN (ileon.eldiario.es), CC BY-NC 4.0; geometría © OpenStreetMap"; `murcia` (55): "Policía Local de Murcia (lista semanal, leída en La Opinión de Murcia); geometría © OpenStreetMap". Both `mobile_announced` sources are police lists read from newspapers, and the León data carries a NonCommercial licence; the Sources screen shows those strings verbatim, so the note says the same ("listas semanales de la Policía Local, publicadas en prensa local"). Open before submission (risk 17): either point the feed's León and Murcia scrapers at the police's own weekly publication and drop the BY-NC dependency, or keep the newspaper sources and settle the BY-NC question for a free GPL app. `reported` is never warned; the app shows the limit and the speed, nothing gamified; "Respeta siempre los límites" in Acerca de.
- Spain, Reglamento General de Circulación art. 18.3: bans "inhibidores de radares o cinemómetros" and "mecanismos de detección", and "Quedan excluidos de esta prohibición los mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico" (https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18). The app is the excluded kind. Availability: Spain only (the data is Spain only; France, Germany and Switzerland restrict warners). App Store Connect primary category Navigation (set in App Store Connect; `LSApplicationCategoryType` is a macOS key and does not set the iOS category: https://developer.apple.com/documentation/bundleresources/information-property-list/lsapplicationcategorytype), age 4+, `ITSAppUsesNonExemptEncryption: false`.
- Privacy: `PrivacyInfo.xcprivacy` in the app and the widget extension (https://developer.apple.com/documentation/bundleresources/privacy-manifest-files): `NSPrivacyTracking false`, no tracking domains, `NSPrivacyCollectedDataTypes` empty (location is used, never transmitted), `NSPrivacyAccessedAPITypes`: UserDefaults `CA92.1` only. Feed age comes from `feed.meta.json`, not file dates (no `C617.1`); elapsed times use `Date` (no `35F9.1`); add either if a lane ends up using those APIs (https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api). Store label "Data Not Collected". Privacy policy `PRIVACY.md`, served from the repo's GitHub Pages.
- Attribution screen: ODbL 1.0 for the database, each source's `attribution` verbatim (including ILEÓN CC BY-NC 4.0 and the Murcia newspaper line until the feed changes), "© OpenStreetMap contributors", "Datos: DGT (CC BY 4.0)", GPL-3.0-or-later and the repo link.
- Code licence: GPL-3.0-or-later with an "App Store additional permission" under GPLv3 section 7 in `LICENSE`/`NOTICE` (the maintainer is the sole copyright holder; `CONTRIBUTING.md` asks contributors for the same grant), because App Store terms are widely held to conflict with plain GPLv3 distribution. Decision for the maintainer (risk 10).
- First app on the personal account: the six Guideline 2.1 items pre-filled in Notes and a physical-device recording of onboarding, Estado, "Probar aviso" and a short drive past a radar with the Live Activity, per the maintainer's App Review notes.

---

## 9. Module layout and lane ownership

Four lanes: **core**, **location**, **surfaces**, **app**. No shared files. The orchestrator commits the contract files first (one hour), then freezes them; afterwards only the orchestrator edits a frozen file, on a lane's request by PR comment. Each lane works in its own worktree and the four meet at one integration build. Toolchain: `Package.swift` at the root, platforms `.iOS(.v18), .macOS(.v14)` so `swift test` runs on a Mac and in CI (`macos-latest`); XcodeGen `App/project.yml` as the single source of truth (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`, `TARGETED_DEVICE_FAMILY "1"` per target, `SKIP_INSTALL YES` on the widget, manual signing in Release with two App Store profiles), patterns from `pumperly-ios/project.yml` and `akou-companion/App/project.yml`; team `624WUVM8B4` only in the gitignored `Local.xcconfig` and in `release.yml`. Bundle ids `io.github.geiserx.radares` and `io.github.geiserx.radares.activity` (both registered). BG task id `io.github.geiserx.radares.refresh`.

```
radares-anunciados/
  Package.swift                                      frozen (orchestrator)   RadaresCore + RadaresCoreTests
  Sources/RadaresCore/
    Thresholds.swift                                 frozen                  every number in this document with its reason as a comment
    Model/Coordinate.swift, Radar.swift, Fix.swift   frozen                  Coordinate, Radar, Kind, Role, Fix
    Engine/AlertEvent.swift, DriveSnapshot.swift     frozen                  AlertEvent, Level, DriveSnapshot
    Health/LogEvent.swift, HealthInputs.swift        frozen                  LogEvent, HealthInputs, HealthItem
    Feed/GeoJSON.swift                               core                    Decodable GeoJSON types
    Feed/FeedDecoder.swift                           core                    decode + normalise (direction, mod 360, twins, roles)
    Feed/FeedValidator.swift                         core                    the five checks of 5.1
    Feed/FeedMeta.swift                              core                    etag, lastModified, fetchedAt, checkedAt, counts, lastError
    Feed/FeedClient.swift                            core                    conditional GET (URLSession, 15 s), FeedFetch result
    Feed/FeedRefreshPolicy.swift                     core                    shouldRefresh(meta:now:trigger:)
    Feed/RadarStore.swift                            core                    load, candidates(near:within:on:), radar(id:), count
    Geo/Geo.swift                                    core                    haversine, bearing, angleDiff, crossTrack, projection
    Engine/WarnPolicy.swift                          core                    warnDistance(speed:), median speed
    Engine/ApproachEvaluator.swift                   core                    ahead, closing, inRange, directionMatch, late
    Engine/PassTracker.swift, PassLedger.swift       core                    per-id state machine; Codable ledger, prune
    Engine/StretchTracker.swift                      core                    gates, inside, remaining, avg, exits
    Engine/DrivingDetector.swift                     core                    3 fixes ≥ 6 m/s; paused/resume rules as pure functions
    Engine/AlertEngine.swift                         core                    ingest(_:) -> [AlertEvent], endDrive(), snapshot, pacing
    Phrasing/Phrasing.swift                          core                    Phrase(spoken, title, body) for every event
    Health/EventLog.swift                            core                    append, rotate, recent(n), export
    Health/HealthReport.swift                        core                    healthReport(_:) rules
  Tests/RadaresCoreTests/                            core
    Fixtures/feed-sample.geojson                                             ~250 real features: all kinds, both 13-vertex lines, -from/-to twins, the A-2 radar, the N-232 stretch dgt_invive-Tramo_Invive_344, a negative OSM bearing
    Fixtures/vectors/*.json                                                  route vectors (fix arrays + expected events); the Android contract; one deliberately broken vector
    FeedDecoderTests, FeedValidatorTests, FeedRefreshPolicyTests, RadarStoreTests, GeoTests, WarnPolicyTests,
    ApproachTests, PassTrackerTests, StretchTrackerTests, DrivingDetectorTests, AlertEngineVectorTests, PhrasingTests,
    EventLogTests, HealthReportTests, PerformanceTests
  App/project.yml, App/Config/*.xcconfig            frozen (orchestrator; app lane edits on request)
  App/Shared/DriveAttributes.swift                   frozen                  DriveAttributes, ContentState, Phase
  App/Sources/
    RadaresApp.swift                                 app                     App + UIApplicationDelegateAdaptor + scenePhase hooks
    AppDelegate.swift                                app                     the six launch steps of 3.3 (no launch-key branch), BG task registration, applicationWillTerminate
    Location/LocationCoordinator.swift               location                actor; bootstrap(state:) starts the stream first, launch reason from the first arrival, startDrive(reason:), stopDrive(), four states
    Location/WakeUps.swift                           location                CLMonitor "radares.wake" + parked condition, SLC manager + delegate
    Location/MotionGate.swift                        location                queryActivityStarting wrapper, positive-only result, run concurrently with the stream
    Location/DriveSession.swift                      location                liveUpdates loop (probe and drive share it) → Fix → AlertEngine → AlertDispatcher; drive state persistence; CLBackgroundActivitySession rejoin, never invalidate from launch
    Surfaces/AlertDispatcher.swift                   surfaces                handle(_ event: AlertEvent) → speech, activity, notification; sink outcomes to the log
    Surfaces/SpeechAnnouncer.swift                   surfaces                AVAudioSession + AVSpeechSynthesizer, pacing, route log, launchContext; per-utterance activation with the once-per-drive fallback behind one switch
    Surfaces/Notifier.swift                          surfaces                Time Sensitive alerts, red-health daily notice, UNUserNotificationCenterDelegate
    Surfaces/DriveActivityController.swift           surfaces                start/update/alert/end/reattach, current; milestone cadence, content read-back, activityUpdated(dropped)
    Intents/StartDriveIntent.swift, StopDriveIntent.swift, RadaresShortcuts.swift   surfaces   LiveActivityIntent pair, AppShortcutsProvider
    Data/FileStore.swift                             app                     folder, protection attribute + read-back, atomic replace, .bak, snapshot copy, excludedFromBackup
    Data/FeedRefresher.swift                         app                     BGAppRefreshTask submit/handle, foreground and drive-start triggers, manual refresh
    Health/HealthMonitor.swift                       app                     collects HealthInputs from the system APIs and the log
    UI/RootView.swift, MapView.swift, HealthView.swift, OnboardingFlow.swift, SettingsView.swift, SourcesView.swift, AlertsListView.swift   app
    Info.plist, Radares.entitlements, PrivacyInfo.xcprivacy, Localizable.xcstrings, Assets.xcassets   app
    Resources/feed-snapshot.geojson, Resources/radar-tick.caf   app
  App/Widgets/RadaresWidgets.swift, DriveLiveActivity.swift, DriveControl.swift, Info.plist, PrivacyInfo.xcprivacy   surfaces
  .github/workflows/ci.yml, release.yml              app                     swift test + xcodegen + simulator build; v* tag → TestFlight; snapshot-age gate
  docs/SPEC.md                                       core                    section 0 scenarios + section 12 (platform-neutral rules, feed contract)
  docs/VERIFY.md                                     location                device checklist; DTS 799094 / 770063 session rules; forum 826964 risk; background-launch speech, Driving Focus (notification and activity alert), Live Activity cadence, CarPlay Simulator sizes, fence wake distance
  docs/CARPLAY.md                                    surfaces                automation recipe, DTS 818467 and 820693, entitlement request text, .carPlay authorization option, iOS 18.4 floor, 10 s refresh rule
  README.md, PRIVACY.md, CONTRIBUTING.md, LICENSE, NOTICE   app
  scripts/update-snapshot.sh (app), scripts/sim-drive.sh (location)
```

Public types each lane exposes (the frozen signatures lanes stub against on day one):

```swift
// core (RadaresCore)
public struct Coordinate: Sendable, Codable, Hashable { public var latitude: Double, longitude: Double }
public struct Radar ... ; public enum Kind ... ; public enum Role ... ; public struct Fix ...        // 2.1
public enum Thresholds { /* warnLeadSeconds 25, warnFloorM 300, warnCapM 1000, aheadDeg 60, bearingToleranceDeg 90,
   closingFixes 2, lateBandM 100, noVoiceBelowM 60, passedFixes 3, passedBelowM 30, cooldownMinutes 10, cooldownMetres 2000,
   pacingSeconds 8, candidateBandM 200, cardMilestonesM [1000, 750, 500, 250, 100], stretchCardStepM 500, courseMinSpeedMps 3, driveSpeedMps 6, driveFixes 3, probeSeconds 60, motionWindowSeconds 180,
   pauseSlowSeconds 120, pauseEndMinutes 10, stretchEntryDeg 60, stretchExitGateM 300, stretchExitSlackM 1000, fenceRadiusM 400,
   feedMinFeatures 2000, refreshForegroundHours 6, refreshBackgroundHours 6, refreshDriveStartHours 24, snapshotMaxAgeDays 30 */ }
public final class RadarStore: Sendable {
    public static func load(geojson: Data) throws -> RadarStore
    public var count: Int { get }; public var countsByKind: [Kind: Int] { get }
    public func candidates(near: Coordinate, within metres: Double, on day: Date) -> [Radar]
    public func radar(id: String) -> Radar?
}
public struct FeedValidator { public static func validate(_ data: Data) -> Result<ValidatedFeed, FeedError> }
public struct FeedClient { public init(session: URLSession = .shared); public func fetch(ifNoneMatch: String?) async throws -> FeedFetch }
public enum FeedFetch { case notModified, updated(Data, etag: String?, lastModified: String?) }
public struct FeedRefreshPolicy { public func shouldRefresh(meta: FeedMeta, now: Date, trigger: Trigger) -> Bool }
public struct WarnPolicy { public static func warnDistance(speed: Double) -> Double }
public final class AlertEngine {
    public init(store: RadarStore, ledger: PassLedger, now: @escaping @Sendable () -> Date = Date.init)
    public func ingest(_ fix: Fix) -> [AlertEvent]          // pure given the store; no I/O
    public func endDrive() -> [AlertEvent]
    public var snapshot: DriveSnapshot { get }               // next radar, distance, stretch state, speed, opposite rows
    public var ledger: PassLedger { get }                    // the owner persists it on .warn/.passed/.driveEnded
}
public struct AlertEvent: Sendable { public enum Kind { case warn(Level), passed, stretchEntered, stretchExited, driveEnded }
    public let kind: Kind, radar: Radar?, distance: Double?, late: Bool, crossTrackMetres: Double?, phrase: Phrase?, content: DriveContent }
public enum Level: Sendable { case full, visual }
public struct PassLedger: Codable, Sendable { public mutating func prune(now: Date) }
public struct DrivingDetector { public mutating func ingest(_ fix: Fix) -> DriveSignal }   // .none, .started, .paused, .resumed, .ended
public struct Phrase: Sendable { public let spoken: String, title: String, body: String }
public enum Phrasing { public static func make(_ event: AlertEvent, locale: Locale) -> Phrase }
public struct EventLog { public init(url: URL); public mutating func append(_ e: LogEvent); public func recent(_ n: Int) -> [LogEvent] }
public func healthReport(_ inputs: HealthInputs) -> [HealthItem]

// location (app target)
public actor LocationCoordinator {
    public static let shared: LocationCoordinator
    public func bootstrap(state: UIApplication.State)   // called from didFinishLaunching; .background → stream first, then probe
    public func startDrive(reason: DriveReason)      // .intent, .foreground, .test
    public func stopDrive()
    public func setWarningsEnabled(_ on: Bool)       // the "Avisos" switch: session, SLC, fence
    public var state: DriveState { get }             // .idle, .probing, .driving, .paused(since:)
}
public enum DriveReason: Sendable { case intent, foreground, test, wakeup(WakeSource) }
public struct MotionGate { public func recentAutomotive(window: TimeInterval) async -> Bool? }   // nil = unavailable or denied

// surfaces (app target + widget)
public final class AlertDispatcher { public static let shared; public func handle(_ event: AlertEvent) async; public var voiceEnabled: Bool }
public final class SpeechAnnouncer { public func speak(_ phrase: Phrase) async -> SpeechOutcome }
public final class Notifier: NSObject, UNUserNotificationCenterDelegate { public static let shared; public func post(_ phrase: Phrase, id: String) async -> Error?; public func postHealthNotice(_ text: String) }
public final class DriveActivityController { public static let shared; public var current: Activity<DriveAttributes>? { get }
    public func start(content: DriveContent) throws; public func update(_ content: DriveContent, alert: Phrase?) async; public func end() async; public func reattach() }
public struct DriveAttributes: ActivityAttributes { public struct ContentState: Codable, Hashable { ... } }   // 2.7
public struct StartDriveIntent: LiveActivityIntent {}, StopDriveIntent: AppIntent {}, RadaresShortcuts: AppShortcutsProvider {}

// app (app target)
public final class FileStore { public static let shared; public var folder: URL; public func replaceFeed(with: Data) throws -> Bool /* protectionVerified */; public func copySnapshotIfNeeded() }
public final class FeedRefresher { public static let shared; public func registerBackgroundTask(); public func refreshIfNeeded(trigger: FeedRefreshPolicy.Trigger) async; public func refreshNow() async }
public final class HealthMonitor { public func collect() async -> HealthInputs }
```

Cross-lane rules: location is the only runtime writer of `EventLog` for location events, surfaces for sink events, app for feed and health events; `DriveAttributes` and `Thresholds` changes go through the orchestrator (one PR); `project.yml` file lists are explicit (no globs across lane folders) and the app lane adds entries on request. Lane sizes: core is the largest and has no platform dependencies; location is the smallest in lines and the most delicate; surfaces and app are UI-shaped.

---

## 10. Verification plan

**Unit (`swift test`, macOS; CI job `core` on `macos-latest`; local runs on a build Mac, never repeat loops on the laptop).**
- FeedDecoder: the fixture decodes to the expected counts per kind; `direction` mapping for all four vocabularies, negatives land in `bearing` mod 360; inactive, `reported` and expired `validTo` excluded by `candidates(on:)` across Europe/Madrid midnight; both `-from` and `-to` twins merged; an unpaired `sct` section stays a point; roles by source.
- FeedValidator: a truncated file, a 1,000-feature file and a file without `fixed` fail; the fixture passes.
- WarnPolicy table (50/80/90/100/120/144 km/h), the clamp edges, the median over a spiky speed series.
- Route vectors (`Fixtures/vectors/*.json`, fixes at 1 Hz along a line): 120 km/h fires once at 833 ± 40 m with the exact sentence; 50 km/h at 347 ± 20 m; a radar 150 m beside a parallel line never fires (not closing); a radar behind never fires; opposite OSM `bearing` → `.visual`; `both` → `.full`; a DGT name → `.full` with the name spoken; course nil at 2 m/s → nothing; late wake at 150 m → `.full` with `late`; first seen at 40 m → card only; U-turn and re-approach after 5 min → no second alert; after 11 min and 3 km → fires; two radars 100 m apart → one spoken, one visual; two in one fix → the combined sentence; corridor entry at either end, remaining distance, `Fin de tramo` at the far gate, silent exit by the straight-line rule, silent exit at 2× traverse; average-speed section with the average computed from the path. Every "must not fire" vector has a "must fire" twin, and one deliberately broken vector (expected warning removed) must fail the suite once during CI setup, so the gate is known to go red. CI fails on zero executed tests.
- PassLedger round-trips through JSON and prunes at 24 h; DrivingDetector: 3 fixes ≥ 6 m/s → started; `isStationary` → paused; a resume at 9 min continues, at 11 min re-probes; 120 s under 1 m/s → paused.
- healthReport: each red/amber rule with a positive and a negative input.
- Performance: `ingest` over the full feed < 10 ms per fix (expected ~0.1 ms); decode < 500 ms.

**Simulator (a build Mac, Xcode 27, iPhone 17 / iOS 26.5; output muted with `osascript -e 'set volume output muted true'` before any run; never on the laptop).** `scripts/sim-drive.sh <udid> <target-id> <km/h> <same|opposite>` reads the target from the fixture, builds waypoints from 3 km before to 1 km after along its bearing, `xcrun simctl privacy <udid> grant location-always io.github.geiserx.radares`, launches with `-StartDriveForTest 1` (foreground start so the Live Activity exists) and runs `xcrun simctl location <udid> start --speed=<m/s> --interval=1 <lat,lon> ...`, then reads `events.jsonl` from `xcrun simctl get_app_container <udid> io.github.geiserx.radares data`. Three cases from section 0: the A-2 point (`dgt-CABINACINEMOMETRO_120001`, 41.30326, −1.94488: a `.full` alert at 833 ± 40 m in both directions with "sentido Zaragoza" spoken), the N-232 stretch `dgt_invive-Tramo_Invive_344` (40.51793, 0.13277 to 40.51235, 0.24688; `stretchEntered` at the near gate from either end with "diez kilómetros" spoken, `stretchExited` at the far gate), and a León `mobileAnnounced` entry with today's date (fires) and yesterday's (silent); plus an OSM radar with a numeric bearing driven against it (`.visual`), and a reversed route inside 10 min (no repeat). A second run with `-NoLiveActivity 1` asserts the Time Sensitive notification instead. A relaunch run: `xcrun simctl terminate`, then `simctl location set` in 500 m steps (the simulator rejects far jumps): the log shows `launch(reason: location)` and `sessionTaken` before `probe`. Lock Screen screenshot at a distance milestone (`xcrun simctl io <udid> screenshot`). Known simulator limits: no suspension, no region cushion or dwell, no real audio route, no Live Activity budget, SLC re-delivered every ~33 s, and no CarPlay: CarPlay Simulator is a Mac app that "connects to iPhone, just like a car" over USB (CarPlay App Programming Guide, p. 8), it does not attach to the iOS Simulator. The simulator proves the logic, not the radio, the scheduler or the car screen.

**Real iPhone only (`docs/VERIFY.md`; the maintainer drives; Estado log exported afterwards).** Fence exit timing and dwell against the speed-dependent expectation of 3.1 (about 0.9 / 1.1 / 1.3 km at 50 / 90 / 120 km/h plus launch and warm-up; Apple's average is 3 to 5 min) and which of fence and SLC fires first; whether 400 m is right; suspension and unsuspension by Core Location at a jam and at a 12-minute stop; relaunch after a system kill (leave the phone a day, then drive); reboot → unlock → drive; the iOS 26 force-quit behaviour (document the result either way); CarPlay Dashboard Live Activity and the bottom alert on iOS 26, first with the iPhone on USB to a Mac running CarPlay Simulator (Additional Tools for Xcode) at the three HIG sizes (240×78, 240×100, 170×78 pt) and the Smart Display Zoom presets (1920×720, 900×1200, 800×480), with Night Mode, then on the real head unit; the Live Activity cadence actually shown (`activityUpdated(dropped:)` rows plus `liveactivitiesd` lines in Console.app) recorded in VERIFY.md; `voicePrompt` routing and ducking through CarPlay and Bluetooth, a podcast pausing and resuming; **background-launch speech**: app terminated, drive started by the CarPlay automation or a simulated wake, never foregrounded, a `speech(..., setActiveError: nil, finished: true, launchContext: background)` row or the once-per-drive activation fallback switched on (4.1); **Time Sensitive through a Driving Focus** and **Live Activity alert through a Driving Focus**, each a pass/fail row; the CarPlay Shortcuts automation; `firstFixAfterWakeS` and `firstWarnAfterWakeM` over a week of drives (the numbers that decide whether v1.1 adds radar rings); a week of Settings › Battery; no jetsam reports in Settings › Privacy › Analytics. The App Review recording comes from this drive.

---

## 11. Open risks

1. iOS 26 may not relaunch a force-quit app for SLC or regions: a developer reports that on iOS 26.4.2 "the app is never relaunched" from force-quit while "the same code on iOS 18 and earlier did relaunch the app", 0 replies (https://developer.apple.com/forums/thread/826964). Mitigation: onboarding says never swipe the app away; Estado turns red on `userTerminated`; the "Conducir" control and the CarPlay automation restart the chain without the user finding the app.
2. The Live Activity cannot be started from a background wake-up. The car screen depends on the automation, the control, the Action button or an opened app; speech and the Time Sensitive notification do not.
3. OSM `direction` semantics are contested; a mis-tagged camera flips `.full` and `.visual` for that camera. Demotion, never suppression, bounds the damage; `suppressedByDirection` in the log; the feed contract asks for explicit semantics.
4. DGT direction names (453 features) warn both ways with the name spoken until the feed ships `bearing`.
5. Stretch geometry is a chord: gates are exact, the inside state and "remaining" are estimates; road-following geometry is a feed request.
6. CarPlay's use of `ActivityFamily.small` is settled by three Apple sources (WWDC25 216, the CarPlay App Programming Guide's "Live Activities in CarPlay" section, the HIG's CarPlay section); only the `ActivityFamily.small` symbol page still says "on watchOS". What remains is a visual check: the three sizes, scaling under the Smart Display Zoom presets and the Night Mode red tint, in CarPlay Simulator over USB and on the real head unit.
7. The first kilometres of a drive: the fence exit is reported about 0.9 / 1.1 / 1.3 km into the drive at 50 / 90 / 120 km/h at best (radius + cushion + 20 s dwell), Apple's own average for region reports is 3 to 5 minutes (6 to 10 km at 120 km/h, network-dependent), SLC is 500 m / 5 min, and after the wake come the launch, up to 30 s of GPS warm-up and the probe fixes; a radar inside that window is missed unless the automation or an opened app started the drive. The missed window is sized on the pessimistic figure, so the case for v1.1 radar rings is stronger than a 600 m wake would suggest: v1.1 adds up to 19 radar rings of 2,500 m (nearest first, diffed against `monitor.identifiers`, `assuming: .unsatisfied`, every flag surfaced, wake-ups only) if `firstWarnAfterWakeM` on real drives confirms the miss; the expectation written in VERIFY.md for that log field is 1 to 3 km, not 600 m.
8. CLMonitor flakiness reports on iOS 18; SLC is the second wake-up and the fence is re-added at every launch.
9. Motion activity flags buses and trains as automotive; passengers get warnings. "Pausar hoy" is the answer.
10. GPL-3.0-or-later on the App Store needs the section 7 additional permission; the maintainer's decision.
11. Reduced-accuracy location makes the app useless (distances ±1 to 2 km, no regions); onboarding and Estado insist on Precise.
12. Drives longer than 8 h lose the Live Activity (platform cap).
13. Decode cost and memory of the 2.9 MB feed on a background launch are estimates until measured on the TestFlight build; the binary cache is the fallback.
14. `BGAppRefreshTask` slots are rare for an app the user never opens; the drive-start refresh at 24 h, the foreground refresh and the red-after-7-days notice cover it.
15. The `audio` background mode may draw a question in review; the note answers it.
16. A parallel road within about 300 m at the warn distance produces a false sentence (section 2.3); `crossTrackMetres` in the log decides whether a lateral limit is added later.
17. Data provenance and licence: the León and Murcia `mobile_announced` lists come from newspapers (ILEÓN under CC BY-NC 4.0, La Opinión de Murcia), not from a police publication (section 8). Decision for the maintainer before submission: re-source the two scrapers to the police's own weekly lists, or keep them and settle the BY-NC question; the app never claims "solo publicaciones oficiales" meanwhile.
18. Live Activity delivery is budgeted and undocumented (4.2): the card may show fewer milestones than sent; `activityUpdated(dropped:)` measures it and the voice carries the exact distance regardless.
19. Speech from a cold background launch is unproven (4.1); the once-per-drive activation fallback is designed and the VERIFY.md test decides which is shipped.
20. Driving Focus may silence the Time Sensitive notification and the Live Activity alert (4.3); voice is the surface that always arrives, and onboarding says so.

---

## 12. Spec for Android (platform-neutral rules, one page)

These rules are the contract both apps implement; `docs/SPEC.md` carries them with the section 0 scenarios and the route vectors in `Tests/RadaresCoreTests/Fixtures/vectors/*.json`, which the Kotlin tests must pass unchanged.

**Feed contract.** `GET https://geiserx.github.io/radares-anunciados-ha/feed.geojson` with `If-None-Match`; 304 keeps the current file. Accept only a `FeatureCollection` with ≥ 2,000 features, ≥ 1 `fixed`, and `id`, `kind`, `geometry` on every feature; replace atomically, keep one backup. Refresh: at app open if older than 6 h, a periodic job every 6 h, at drive start if older than 24 h, manual. Stale data never disables alerts. Kinds: `fixed`, `section`, `stretch`, `mobile_announced`, `trailer`, `reported`. Roles: `stretch` from `dgt_invive` = mobile corridor (bidirectional); any other `stretch` = average-speed section; `section` points whose coordinates equal a stretch endpoint merge into that stretch (both ends); the rest are points. `direction`: numeric → bearing mod 360 (monitored-traffic heading, contested); `both` → bidirectional; a name → `directionText`, spoken, never used to gate; null → nothing. Alertable: `active`, not `reported`, and for `mobile_announced` today (Europe/Madrid) within `valid_from...valid_to`. Optional future fields honoured when present: `bearing` + `direction_semantics: "travel"` (the only field that may suppress), `geometry_is_chord`, `section_of`, `generated`.

**Fix.** 1 Hz while driving: coordinate, timestamp, speed (null when invalid), course (null when the platform marks it invalid, or below 3 m/s, our own threshold, tuned from logged drives; else derived from the last two fixes ≥ 15 m apart), accuracy. Speed for the distance = median of the last three valid speeds. No course → no alert, card only.

**Alert distance.** `warn = clamp(25 s × speed, 300 m, 1,000 m)`: 50 km/h 347 m, 90 625 m, 120 833 m, 144+ 1,000 m. Candidates within `warn + 200 m`. Fire when: ahead (angle between course and bearing to the gate ≤ 60°), closing (distance fell on the last two fixes by ≥ 1 m), in range (≤ warn), and the direction gate: bearing present and not bidirectional → `|course − bearing| ≤ 90°` else demote to `visual` (shown, not spoken, no notification). Names and null always `full`. First seen inside `warn − 100 m` still fires, flagged late; below 60 m and closing: no voice. Passed: distance up on three consecutive fixes after the minimum, or < 30 m; show "passed" 4 s.

**Once per pass, cooldown.** Per radar id: armed → fired → passed → cooldown → idle. Re-arm only when 10 min have passed since firing AND the car has been ≥ 2 km from the radar since. Persist the ledger on fire, on pass and at drive end (never per fix); prune at 24 h; ≤ 200 entries; it must survive a process restart. Pacing: one spoken alert per 8 s, later ones in the gap are visual; two in one fix are one sentence ("Radar fijo a 600 metros, y otro a 800").

**Stretches.** Two gates (endpoints) + inside state; the chord is only for the remaining estimate. Entry = the point rule at the nearer endpoint plus course within ±60° of the chord bearing from that endpoint toward the other; corridors and sections without a bearing enter from either end; an OSM bearing on a section follows the direction gate. Inside: badge with remaining (chord minus projection, "aprox.") and, for average-speed sections, average = path length since entry / elapsed. Exit: within 300 m of the far gate (say "Fin de tramo"), or straight-line distance from the entry gate > max(road length, chord) + 1,000 m (silent), or 2× the traverse time expected at entry speed (silent), or drive end. One pass per stretch id.

**Direction rules (summary).** Numeric bearing: gate ±90°, mismatch demotes, never hides. `both`, name, null: full, the name spoken. Future `bearing` with `direction_semantics: "travel"`: hard gate.

**Driving detection and wake-ups.** On a background wake start the 1 Hz location stream first and query activity recognition concurrently (the stream is what keeps the process alive; a wake with no service running has seconds): drive after three fixes ≥ 6 m/s within a 60 s probe, or at once when the activity-recognition API reports in-vehicle with ≥ medium confidence in the last 3 min (a negative never skips the probe). Pause on stationary or 120 s below 1 m/s, keep listening; a resume within 10 min continues the same drive and ledger; after 10 min re-probe; walking ends the drive. Idle cost must be zero GPS: wake on leaving a 400 m fence around the parked position and on the platform's coarse movement signal, as co-equal wake-ups; expect the first warning 1 to several km into a cold-wake drive (geofence latency is platform- and network-dependent) and log `firstWarnAfterWakeM` to decide radar rings. Android: `FusedLocationProviderClient` at 1 Hz inside a foreground service of type `location` while driving; Geofencing API for the parked fence (one of 100); Activity Recognition Transition API `IN_VEHICLE` as the motion gate; WorkManager periodic 6 h for the feed; `TextToSpeech` with `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` and `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`; a high-importance channel for the alert; the ongoing drive notification updates at the same milestones as the iOS card (phase changes, 1,000 / 750 / 500 / 250 / 100 m, 500 m steps inside a stretch), never per fix; Android Auto only shows CALL/MESSAGE/NAVIGATION categories and OEMs may hide NAVIGATION, and Do Not Disturb while driving can hold notifications, so speech is the one guaranteed car surface there too.

**Phrasing (es).** Distances rounded to 50 m, limit only when known, direction name appended when present: "Radar fijo a 800 metros. Límite 90.", "Radar fijo a 650 metros, sentido Zaragoza.", "Radar de tramo a 600 metros, 3 kilómetros. Límite 100.", "Tramo de radar móvil, N-232, diez kilómetros.", "Radar móvil anunciado a 350 metros. Límite 50.", "Radar en remolque a 800 metros.", "Fin de tramo."

**Health.** Log every launch reason (derived from the first event that arrives, never from a launch flag), wake-up, probe result, drive start/pause/end with `firstFixAfterWakeS`, `firstWarnAfterWakeM` and `maxGapSeconds`, every alert with level, distance, speed, late, cross-track and sinks, every sink failure (including a car-surface update the system dropped, read back after sending), every feed result. A self-test pushes a synthetic radar 600 m ahead through the real engine and the real sinks. A plain notification at most once per 24 h when the app is red and closed.

---

## Appendix. Verified claims (2026-10-07)

Claims checked against the live page or the live feed on 2026-10-07. A URL appears where one was used; quoted text was checked verbatim.

**Core Location**
- CLMonitor cap: "Core Location prevents any single app from monitoring more than 20 conditions of any type simultaneously"; relaunch, recreate-by-identifier and unlock-after-reboot sentences verbatim. https://developer.apple.com/documentation/corelocation/monitoring-the-user-s-proximity-to-geographic-regions
- An exit event also launches a terminated app (WWDC23 10147); "If your assumption of the state is wrong, Core Location will give you the correct state once it is determined" verbatim. https://nonstrict.eu/wwdcindex/wwdc2023/10147/
- `CLMonitor.add(_:identifier:assuming:)` and `CLMonitor.identifiers` exist as used. https://developer.apple.com/documentation/corelocation/clmonitor-2r51v
- `CLMonitor.Event` flags named in 3.2 all exist. https://developer.apple.com/documentation/corelocation/clmonitor-2r51v/event · `CLLocationUpdate` flags. https://developer.apple.com/documentation/corelocation/cllocationupdate
- Archived Location Awareness PG: cushion "approximately 200 meters" (for testing), "remain at that minimum distance for at least 20 seconds", Wi-Fi off makes region monitoring "significantly less accurate", a suspended app gets "around 10 seconds". https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/LocationAwarenessPG/RegionMonitoring/RegionMonitoring.html
- "the region monitoring service requires network connectivity" verbatim; `startMonitoring(for:)` deprecated at iOS 27.2 in favour of CLMonitor. https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoring(for:)
- Significant-change: "500 meters or more", "not more frequently than once every five minutes", timelier with network; not deprecated. https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()
- Authorization table: When in Use "No. The user must launch the app." / Always "Yes for significant location change, visits, and region monitoring services; no for others"; a WIU app with the background mode "continues to run in the background when location services are active"; the later Always request "you can make the request only once". https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services
- `requestAlwaysAuthorization()`: "immediately prompts", Allow Once ignores further calls, "further calls have no effect", options "Keep Only While Using" / "Change to Always Allow", When In Use first then Always; Provisional Always only on the direct-from-notDetermined path. https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization()
- Background guide: "Create the session while your app is in the foreground. If your app terminates, you must recreate the CLServiceSession immediately upon launch in the background."; implicit When in Use via CLMonitor / CLLocationUpdate / CLBackgroundActivitySession unless `NSLocationRequireExplicitServiceSession`; "Don't start these services at launch time if your app's authorization status is undetermined." https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background
- WWDC24 10212: Always effective only while holding a session started in the foreground; liveUpdates and CLMonitor.events "won't yield results when it is not in use, unless a session [...] asserts that continued interest"; sessions tracked "for only a few seconds after the app is launched again"; "you'll need to take an explicit CLServiceSession with .always". https://nonstrict.eu/wwdcindex/wwdc2024/10212/
- WWDC23 10180: "updates will automatically resume without any user interaction"; "we will unsuspend your app"; "We will recover your app as soon as location updates are available by launching it in the background"; "you can only rejoin an existing one from the background"; "Your app still needs to have location in its UIBackgroundModes array". https://nonstrict.eu/wwdcindex/wwdc2023/10180/
- `isStationary` sentences verbatim. https://developer.apple.com/documentation/corelocation/cllocationupdate/isstationary
- `CLBackgroundActivitySession` "allows a when-in-use authorized app to receive location updates or monitoring events". https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3
- CLServiceSession is iOS 18.0+; CLMonitor, `liveUpdates(_:)`, `LiveConfiguration` (including `.automotiveNavigation`) are iOS 17.0+. https://developer.apple.com/documentation/corelocation/clservicesession-pt7n
- `accuracyAuthorization` reduced: "your app can't use region monitoring or beacon ranging". https://developer.apple.com/documentation/corelocation/cllocationmanager/accuracyauthorization
- SwiftUI apps need `UIApplicationDelegateAdaptor` + `didFinishLaunchingWithOptions` so delivery resumes on "launch of the app, or relaunch after a crash"; `application(_:didFinishLaunchingWithOptions:)` is not deprecated on iOS 26. https://developer.apple.com/documentation/corelocation/supporting-live-updates-in-swiftui-and-mac-catalyst-apps
- `kCLLocationAccuracyBestForNavigation`: "use this level of accuracy only while the device is plugged in". https://developer.apple.com/documentation/corelocation/kcllocationaccuracybestfornavigation
- Core Motion: "A delay of up to several minutes in reported activities is expected"; seven-day store. https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager/queryactivitystarting(from:to:to:withhandler:) · without `NSMotionUsageDescription` "your app crashes when you call this API". https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager

**Developer Forums (DTS and Apple engineers)**
- 799094: "If you are using an explicit session, you will want to recreate the session asap upon launch in the background, otherwise your app will be assumed to no longer have interest in location updates [...]". https://developer.apple.com/forums/thread/799094
- 770063 (Argun Tekant): the two failures, invalidating the CLBackgroundActivitySession after a kill and not rejoining it from a non-UI launch path. https://developer.apple.com/forums/thread/770063
- 826964: iOS 26.4.2 force-quit app "never relaunched" over 30 km of SLC and 2 km regions, iOS 18 did; 0 replies. https://developer.apple.com/forums/thread/826964
- 768373: CLMonitor unreliable on iOS 18, no Apple reply; OP's own diagnosis is a missing CLServiceSession. https://developer.apple.com/forums/thread/768373
- 820693 (Albert, WWDR): no programmatic CarPlay wake; Shortcuts automation on CarPlay Connects with Run Immediately; warning against Core Motion / Core Location vehicle wake-ups. https://developer.apple.com/forums/thread/820693
- 818467 (Albert Pascual): "it is not possible to programmatically initiate a Live Activity from a background execution context, such as a CLLocationManager wakeup, using local APIs"; a Shortcut, interactive widget or Siri running a LiveActivityIntent is granted the privilege. https://developer.apple.com/forums/thread/818467
- 795990: "Notifications on CarPlay requires the app icon present on the CarPlay Home Screen"; "Driving Task apps are expected to be able to show notifications on the car screen as of iOS 18.4". https://developer.apple.com/forums/thread/795990
- 764335 (Argun Tekant): speech cannot be produced from a Notification Service Extension (the design never relies on that path).

**ActivityKit, WidgetKit, App Intents, CarPlay**
- `Activity.request`: "you can't do this while your app is in the background, unless you adopt App Intents and start the Live Activity using a LiveActivityIntent"; `ActivityAuthorizationError.visibility` = "The app tried to start the Live Activity while it was in the background."
- `LiveActivityIntent`: "the system launches your app process without opening the app, performs the intent, and starts the Live Activity" (iOS 17.0+, 17.2 per the floor list).
- Controls: "from Control Center, the Lock Screen, and the Action button"; `ControlWidgetButton` iOS 18.0+; `AppShortcutsProvider` as cited.
- Shortcuts: CarPlay is among the personal automations that run without confirmation; only "Antes de ir al trabajo" is excluded.
- `Activity.update(_:)` allowed in foreground or background; 4 KB cap; `end(_:dismissalPolicy:)` allowed from the background; `.after(_:)` within a four-hour window. 8 h active, up to 4 more on the Lock Screen, 12 h max; `staleDate` semantics; "Buttons and toggles on Live Activities don't perform actions in CarPlay".
- `AlertConfiguration.AlertSound` exposes exactly `.default` and `.named(_:)`; the screen-lighting and Dynamic Island facts live in the HIG, not on the `update(_:alertConfiguration:timestamp:)` page.
- HIG: "don't use push notifications alongside Live Activities for the same updates"; "When a Live Activity ends, the system immediately removes it from the Dynamic Island and in CarPlay"; CarPlay sizes 240×78, 240×100, 170×78 pt; Smart Display Zoom presets 1920×720, 900×1200, 800×480; Night Mode red tint; "declare support for a small supplemental activity family".
- WWDC25 216 quotes verbatim (activity family small, compact fallback, bottom-of-display notification when Dashboard is hidden, non-interactive). CarPlay App Programming Guide: "Your app does not need to be a CarPlay app to support widgets and Live Activities in CarPlay"; "Live Activities are supported with iOS 26 in CarPlay and CarPlay Ultra" (no entitlement). https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf
- `supplementalActivityFamilies(_:)`, `EnvironmentValues.activityFamily`, `ActivityFamily`, `ActivityFamily.small` are iOS 18.0+; `ActivityConfiguration` conforms to `WidgetConfiguration`.
- CarPlay entitlements are requested at developer.apple.com/contact/carplay with the CarPlay Entitlement Addendum; `com.apple.developer.carplay-driving-task` exists (iOS 14); `CPInformationTemplate` is available to driving-task apps.
- `allowInCarPlay`: "Apps must be approved for CarPlay overall and then you must enable CarPlay for the notification types you want displayed".

**Notifications**
- `UNNotificationInterruptionLevel.timeSensitive`: "The system presents the notification immediately, lights up the screen, can play a sound, and breaks through system notification controls"; "can break through system controls such as Notification Summary and Focus. The user can turn off the ability for time sensitive notification interruptions."
- `UNAuthorizationOptions.timeSensitive` iOS 15.0 to 15.0, "Use time-sensitive entitlement"; WWDC21 10091 "enable the associated capability via Xcode"; `timeSensitiveSetting` iOS 15.0+. Same session: "Communication and Time Sensitive notifications will be announced by default" (Siri Announce Notifications), a voice path the design does not count on.

**Audio**
- `AVAudioSession.Mode.voicePrompt` verbatim; Apple adds "apps of the same type also configure their sessions to use the duckOthers and interruptSpokenAudioAndMixWithOthers options", the design's option set.
- `interruptSpokenAudioAndMixWithOthers` pauses `.spokenAudio` sessions and resumes them with `notifyOthersOnDeactivation`; a player that does not set `.spokenAudio` is ducked, not paused. `duckOthers` temporary use only.
- `.playback` continues "with the Silent switch set to silent or when the screen locks" and needs the `audio` background mode to keep playing in the background; `cannotStartPlaying` quote verbatim.
- `AVSpeechSynthesizer`: "you need to manually retain it until speech concludes"; utterance queue as the pacing rule relies on.

**Background refresh, privacy, files, encryption**
- `BGAppRefreshTask` needs the `fetch` background mode; registration "must be complete before the end of applicationDidFinishLaunching(_:)"; WWDC19 707 "your app will get 30 seconds of run time"; `backgroundRefreshStatus`: "Background App Refresh is disabled automatically when a device is operating in low-power mode"; WWDC20 10078 "aim for less than 50 megabytes".
- Privacy manifest: every bundle with its own executable using a required-reason API needs one (the widget's UserDefaults use needs CA92.1 too); `FileManager.attributesOfItem(atPath:)` is not in the C617.1 list and `Date` is not in the 35F9.1 list, so "no C617.1, no 35F9.1" holds; "Data Not Collected" follows from an empty collected-data list.
- `completeUntilFirstUserAuthentication` quote verbatim; `ITSAppUsesNonExemptEncryption: NO` skips the export questionnaire.

**Review, legal, deployment floor**
- Guideline 2.5.4 current text (no battery-reminder sentence); 1.4.4 "Apps may only display DUI checkpoints that are published by law enforcement agencies, and should never encourage drunk driving or other reckless behavior such as excessive speed."
- RGC art. 18.3 (BOE-A-2003-23514) bans inhibidores and detection devices and excludes "los mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico"; Germany §23(1c) StVO bans warner functions including smartphone apps; age rating 4+ exists in the 2025 tiers; the GPL / App Store conflict is real (VLC pulled January 2011, back after relicensing: https://en.wikipedia.org/wiki/VLC_media_player).
- Norma 3.1-IC minimum radius at 120 km/h = 700 m with 8 % peralte. https://www.bizkaia.eus/Home2/archivos/DPTO10/Temas/Anejo%20N%C2%BA05_Trazado%20Geom%C3%A9trico%20y%20Replanteo_0.pdf?idioma=CA
- Deployment floor: CLServiceSession, `supplementalActivityFamilies`, `ControlWidgetButton` iOS 18; `LiveActivityIntent` iOS 17.2; CarPlay Live Activities iOS 26.

**Feed (measured on the live file)**
- Headers 2026-10-06: 2,885,752 bytes, ETag `"6ac53e00-2c0878"`, Last-Modified Tue 06 Oct 2026 18:29:20 GMT, 4,452 features, 171,575 bytes as served gzipped, 156,628 bytes with `gzip -9` locally (the document's 156,615 is a gzip build difference); `status.json` exists (200, 6,789 bytes). https://geiserx.github.io/radares-anunciados-ha/feed.geojson
- Structure: only `features` / `type` at top level (no `generated`); 2,860 Points + 1,592 LineStrings; ids unique; property keys as listed in 5.5; `radius_m` values 1200 / 1533 / 756 / 533.
- Kinds: fixed 2,263, stretch 1,592, section 359, mobile_announced 147 (leon 92 + murcia 55), trailer 53, reported 38 (all `osm_notes`); maxspeed null 2,412; inactive 77 (all mobile_announced).
- `direction` vocabulary, stretch geometry statistics, section twins (328 of 359 on a stretch endpoint, 165 `-from`, 163 `-to`, 252 stretches with a section at the first vertex, 31 remaining), densest 0.1° 3×3 neighbourhood 280 features: all as written in 2.1 and 2.5.
- A-2 radar `dgt-CABINACINEMOMETRO_120001` at [−1.94488, 41.30326], direction "ZARAGOZA", maxspeed null, radius_m 1533; León "Avenida de Europa" entries exist (`leon-2026-10-06-avenida-de-europa-0/1`, maxspeed 50); Z-40 has only the `dgt` stretch `dgt-CVM_161274` (km 26.6 to 29.7). N-232 `dgt_invive` stretch `dgt_invive-Tramo_Invive_344` km 20.81 to 30.91 re-checked on 2026-10-07.
- "About 4,340 alertable" is right for 2026-10-06 (4,337); on 2026-10-07 it is 4,308 because the 29 León entries dated 2026-10-06 expired overnight. Date-dependent, not an error.
- Attribution strings: dgt "Dirección General de Tráfico (CC BY 4.0), actualizado 2025-12-18"; dgt_invive "Creative Commons Attribution"; osm / osm_notes "© OpenStreetMap contributors (ODbL 1.0)".
- Feed cadence: `radares-anunciados-ha` `feed.yml` runs on cron `17 */6 * * *`, so the 6 h refresh matches the publisher.
- Warn-distance arithmetic (2.2), the 20.6° ≈ 21° parallel-road example, the 1 Hz fix lengths, the 60 m no-voice band and the 2 km cooldown times all check out.
