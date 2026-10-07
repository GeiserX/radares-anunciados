# Radares Anunciados: the platform-neutral spec

What both apps (iOS now, Android later) must do, written so a Kotlin port can be built and checked against the
same files. The iOS design with its reasons and sources is `docs/DESIGN.md`; this file is the contract.

## 0. The moment on the road

Three drives. The route vectors replay them, the simulator script drives them, the real-car checklist repeats them.

**120 km/h, A-2, fixed radar `dgt-CABINACINEMOMETRO_120001` at km 202.3, direction text "ZARAGOZA", limit unknown.**
The phone is locked in a pocket; the app was never opened today. At about 833 m the speakers say once, over the
music, which ducks: *"Radar fijo a 800 metros, sentido Zaragoza."*, and a Time Sensitive notification `Radar fijo a
800 m` / `A-2 km 202,3 · sentido Zaragoza` lights the Lock Screen at the same moment. Past the radar the
notification is removed. Driving the other way past the same radar the app also warns: the feed gives a town name,
not a bearing, so the sentence says the direction and the driver judges. Vectors `a2-120kmh-ne` and `a2-120kmh-sw`.

**90 km/h, N-232, `dgt_invive` mobile-radar stretch `dgt_invive-Tramo_Invive_344`, km 20.81 to 30.91, direction `both`.**
At 625 m from the nearer endpoint, heading into the stretch: *"Tramo de radar móvil, N-232, 10 kilómetros."* and
the notification `Tramo de radar móvil · 10 kilómetros` / `N-232`. The in-app card, when the app is open, shows the
remaining distance for the whole stretch. Within 300 m of the far end: *"Fin de tramo."*. Vectors
`corridor-n232-from-west` and `corridor-n232-from-east`.

**50 km/h, a León street on the police weekly list, limit 50, `valid_from` = `valid_to` = today.** At 347 m:
*"Radar móvil anunciado a 350 metros. Límite 50."* Tomorrow the same street is silent. Vectors `leon-50kmh-today`
and `leon-50kmh-tomorrow`.

In all three the phone was locked in a pocket and the app had not been opened that day.

## 1. Feed contract

`GET https://geiserx.github.io/radares-anunciados-ha/feed.geojson` with `If-None-Match: <etag>`, a 15 s timeout,
cellular allowed; a 304 keeps the current file and moves `checkedAt`. Accept a body only when it is a
`FeatureCollection` with at least 2,000 features, at least one `fixed`, and `id`, `kind` and `geometry` on every
feature; replace the stored file atomically and keep one backup. A body that fails keeps the old file and is a red
event. Refresh: at app open if the body is older than 6 h, a periodic job every 6 h, at drive start if older than
24 h, and on demand. Stale data never disables alerts.

What is read from each feature: `id`, `geometry` (`Point` or `LineString`, `[lon, lat]`), and in `properties`:
`kind`, `name`, `source`, `active`, `maxspeed`, `direction`, `province`, `url`, `attribution`, `valid_from`,
`valid_to`, `road`, `km_from`, `km_to`. Unknown properties are ignored. A feature with an unknown `kind`, an unknown
geometry type, no `id` or no usable coordinates is skipped, never fatal.

Kinds: `fixed`, `section`, `stretch`, `mobile_announced`, `mobile_recurring` (a spot where a mobile radar is set up
often, derived from published fines; no dates, alertable while `active`), `trailer`, `reported`.

Roles, derived: a `stretch` from source `dgt_invive` is a **mobile corridor** (bidirectional); any other `stretch` is
an **average-speed section**; everything else is a **point**. A `section` point whose coordinates equal an endpoint
of a stretch (either end, any stretch) is that stretch's gate: it is folded into the stretch and dropped, and its
`maxspeed` fills the stretch's when the stretch has none. The sections that sit on no endpoint stay points and are
spoken as "Radar de tramo".

`direction`, four vocabularies in one string:

| value | meaning | effect |
|---|---|---|
| a number (`"75"`, `"-40"`) | OSM heading of the monitored traffic, contested | `bearing = ((x mod 360) + 360) mod 360`; gate with demotion, never suppression |
| `"both"` | both flows | `bidirectional = true`, always full |
| a place name (`"ZARAGOZA"`) | the direction as a sign would say it | `directionText`, spoken and shown, never used to gate |
| `null` | unknown | nothing |

OSM's relative tokens `forward` and `backward` name no place and carry no absolute heading: treated as `null`.

Lengths: `roadMetres = |km_to - km_from| * 1000` when both are present; `chordMetres` = sum of the LineString's
segment lengths. The spoken length is `roadMetres` when present, else `chordMetres`. Vertex order carries no
direction (22 stretches have `km_from >= km_to`).

`valid_from` / `valid_to` are `yyyy-MM-dd` calendar days in Europe/Madrid, inclusive.

Alertable, evaluated per fix: `active`, `kind != reported`, and for `mobile_announced` the Europe/Madrid calendar day
of the fix inside `valid_from...valid_to` (an entry with neither date is never alertable).

Optional future fields, honoured when present and ignored when absent: `bearing` with `direction_semantics: "travel"`
(the only field that may hide a radar), `geometry_is_chord`, `section_of`, `generated`.

## 2. Fix

One position per second while driving: coordinate, timestamp, speed in m/s (null when the platform marks it
invalid), course in degrees (null when the platform marks it invalid), horizontal accuracy in metres, and a
stationary flag. The engine's clock is the fix timestamp.

Course in use: the platform course when it is non-null and the fix's speed is at least 3 m/s; the platform course
when it is non-null, the speed is null (marked invalid) and the car moved at least 3 m per second since the previous
fix; otherwise the bearing from the most recent fix of the last 5 s that is at least 15 m behind this one (so from
3 m/s up: fixes 2 m apart derive nothing); otherwise none. With no course nothing fires and the in-app card shows
the nearest radar as "cerca". Vectors `a2-no-course-2mps` (silent), `a2-no-course-6mps`, `a2-no-course-20mps` and
`a2-speed-nil-course-10mps`.

Speed for the warn distance: the median of the last three valid speeds (two values: their mean; none: 0).

## 3. Alert distance and the point rule

`warn = clamp(25 s × speed, 300 m, 1,000 m)`: 50 km/h 347 m, 80 556 m, 90 625 m, 100 694 m, 120 833 m, 144 and
above 1,000 m.

Candidates: alertable radars within `warn + 200 m` of the fix, nearest first: a point by its position, a line by its
nearer endpoint or by the straight line between its endpoints (so a car between the gates sees the stretch,
section 5). For each candidate the distance to its gate is recorded on every fix while it stays a candidate (the
history restarts when it leaves the band).

A point fires on the first fix where all four hold:

1. **ahead**: angle between the course and the bearing from the car to the gate ≤ 60°;
2. **closing**: the distance decreased by at least 1 m on each of the last two fixes (so at least two earlier
   distances exist);
3. **in range**: distance ≤ `warn`;
4. **direction**: `bearing` is null, or the radar is bidirectional, or `|course − bearing| ≤ 90°` (mod 360).

1 to 3 with 4 failing is a **visual** warning (the notification titled "…, sentido contrario", silent, not spoken; section
6); 1 to 4 is **full**. **Late** when the first recorded distance was under `warn − 100 m`; late warnings still fire. Under 60 m
and closing: fires as visual (the notification without the voice, the sentence would end after the radar).

Passed: on a later fix, distance under 30 m, or three consecutive increases of at least 1 m after the minimum (a
smaller step or a decrease resets the count) with the distance at least `max(3 m, accuracy)` above that minimum, so
GPS wander while stopped before the radar is not a pass. The in-app card shows "Radar superado" for 4 s and the
radar's notification is removed. Vector `a2-stopped-jitter-200m`.

Only points, corridors and sections fire. `reported`, inactive and expired entries are never candidates.

## 4. Once per pass, cooldown, pacing

Per radar id: idle → armed (candidate and ahead) → fired(level) → passed → cooldown → idle. A fired or passed radar
re-arms only when **both** 10 min have gone by since firing **and** the car has been at least 2 km from it since. A
radar demoted to visual stays visual for that pass. The ledger (id, firedAt, level, farthest distance since,
passedAt) is persisted on fire, on pass and at drive end, never per fix, pruned at 24 h, at most 200 entries. It
must survive a process restart mid-drive: the voice never repeats. Vectors `a2-uturn-5min` (same pass) and
`a2-uturn-11min-3km` (new pass).

Pacing: one spoken warning per 8 s; a full point warning inside the gap becomes visual. A stretch entry is always
spoken (it is the one sentence of a stretch that can run for 30 km, and the synthesizer queues it behind the point's
sentence) and resets the clock, so a point firing within 8 s after it is visual. Two full warnings on one fix are
one sentence, nearest first: *"Radar fijo a 500 metros, y otro a 600."*; the second event is visual. Vectors
`pair-123m-pacing` and `pair-123m-same-fix`.

## 5. Stretches

A stretch is two gates (its endpoints) plus an inside state; the straight line between the gates is only used for the
remaining estimate.

Entry: the point rule of section 3 against the nearer endpoint, plus the course within 60° of the bearing from that
endpoint toward the other. A mobile corridor (always `both`) and an average-speed section without a bearing enter
from either end. An average-speed section with an OSM bearing follows the direction gate: on mismatch the entry is a
visual warning and the car is not inside. Spoken at entry: corridor *"Tramo de radar móvil, {road}, {length}."*;
section *"Radar de tramo a {d} metros, {length}[, sentido {Name}].[ Límite {max}.]"*.

Entry between the gates (a car that joined from a side road and crosses no gate): the car is inside after 3
consecutive fixes whose projection onto the chord falls between the gates with a 300 m margin at each end, within
150 m of the chord, with the course within 60° of the chord in either direction (a section with an OSM bearing
follows the direction gate; a mismatch is no entry). The entry gate is the one behind, the remaining length is the
chord ahead, the event's `distance` is that remaining length, and the sentence says what is left: corridor
*"Tramo de radar móvil, {road}, quedan {length}."*; section *"Radar de tramo, quedan {length}[, sentido {Name}].[ Límite {max}.]"*.
Vector `corridor-n232-mid-join`.

Inside: remaining = straight-line gate distance minus the projection of the car onto it, captioned "aprox." by the
surfaces, shown in 500 m steps; for an average-speed section also the average = path length since entry / elapsed
time. No second voice prompt. The stretch is "fired" in the ledger from entry, so it is one pass. A point inside the
stretch fires as any point does and owns the in-app card while ahead and for its 4 s "Radar superado"; the stretch
card returns afterwards. The ledger carries the stretch the car is inside (radar, entry gate, entry position, time and
speed), written at entry and cleared at exit: a process restarted mid-stretch resumes it (a resumed drive only, never a new one) and still says
*"Fin de tramo."* at the far gate, estimating the path before the restart as the straight distance from the entry
position.

Exit, whichever comes first: within 300 m of the far gate (spoken *"Fin de tramo."*); straight-line distance from the
entry gate over `max(roadMetres, chordMetres) + 1,000 m` (silent); elapsed time over 2× the traverse time expected
at the entry speed (silent); drive end (silent). After an exit the next stretch sharing that gate may enter on the
following fixes. Vectors `corridor-n232-*` and `section-z40-100kmh`.

## 6. Phrasing

Distances are rounded to 50 m (never under 50); lengths of 950 m or more are whole kilometres as digits
("10 kilómetros", "1 kilómetro"), shorter ones metres; the limit is appended only when known; the direction name is
title-cased and appended when present. Spanish is the default; English only when the phone's language is English.

| event | Spanish | English |
|---|---|---|
| fixed | Radar fijo a 800 metros. Límite 90. | Fixed speed camera 800 metres ahead. Limit 90. |
| fixed with name | Radar fijo a 650 metros, sentido Zaragoza. | Fixed speed camera 650 metres ahead, towards Zaragoza. |
| two on one fix | Radar fijo a 600 metros, y otro a 800. | Fixed speed camera 600 metres ahead, and another at 800. |
| unpaired section | Radar de tramo a 600 metros. | Average speed camera 600 metres ahead. |
| section entry | Radar de tramo a 600 metros, 3 kilómetros. Límite 100. | Average speed section 600 metres ahead, 3 kilometres. Limit 100. |
| corridor entry | Tramo de radar móvil, N-232, 10 kilómetros. | Mobile radar stretch, N-232, 10 kilometres. |
| mobile announced | Radar móvil anunciado a 350 metros. Límite 50. | Announced mobile speed camera 350 metres ahead. Limit 50. |
| mobile recurring | Radar móvil habitual a 350 metros. Límite 50. | Usual mobile radar 350 metres ahead. Limit 50. |
| trailer | Radar en remolque a 800 metros. | Trailer speed camera 800 metres ahead. |
| stretch exit at the far gate | Fin de tramo. | End of section. |

Never spoken: `reported`, inactive, expired, in cooldown, behind, visual, passed, silent exits.

Notification title `Radar fijo a 800 m`, body `A-2 km 202,3 · límite 90 km/h` (road and km when the feed has them,
else the name; then the limit, then `sentido Zaragoza`). Every warning posts one, at the platform's time-sensitive
level, with a short tick beside the voice (the default sound when the voice is off); a visual warning posts the same
text without the voice, with `, sentido contrario` in the title and no sound for the opposite flow. One notification
per radar pass and per stretch entry; the previous radar's is removed when the next fires or at pass. Nothing has to
be opened or left on screen for it.

## 7. Card content

The in-app card (the map screen, while the app is open) renders: `phase` (watching, approaching, alert, passed,
insideStretch, paused, degraded), a kind symbol, title ("Radar fijo"), subtitle (road and km, or the name, or
"cerca"), distance in metres, limit, speed in km/h, `opposite`, remaining metres and average km/h inside a stretch, a
note (never "aprox.": that is the surfaces' caption on the remaining figure), and the time. The idle title is "Sin
radares cerca" / "No radars nearby" by locale. It follows every fix; the voice carries the exact distance.

## 8. Driving detection and wake-ups

On a background wake, start the 1 Hz location stream first and query activity recognition concurrently: a drive
starts after three fixes at 6 m/s or more within a 60 s probe, or at once when the activity API reports in-vehicle
with at least medium confidence in the last 3 min (a negative never skips the probe). Pause on the stationary flag
or after 120 s under 1 m/s, keep listening; a resume at 3 m/s or more within 10 min continues the same drive and
ledger; after 10 min the drive ends and the next fixes re-probe; walking ends the drive. Idle cost is zero GPS: wake
on leaving a 400 m fence around the parked position and on the platform's coarse movement signal, as co-equal
wake-ups. Log `firstFixAfterWakeS` and `firstWarnAfterWakeM` on every drive.

Android mapping: `FusedLocationProviderClient` at 1 Hz inside a foreground service of type `location` while driving;
the Geofencing API for the parked fence; the Activity Recognition Transition API `IN_VEHICLE` as the motion gate;
WorkManager periodic 6 h for the feed; `TextToSpeech` with `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE` and
`AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`; a high-importance channel for the alert notification, one per warning as in
section 6. Android Auto only shows CALL, MESSAGE and NAVIGATION
categories and Do Not Disturb while driving can hold notifications, so speech is the one guaranteed car surface.

## 9. Health

Log every launch reason (derived from the first event that arrives, never from a launch flag), wake-up, probe
result, drive start, pause and end (with `firstFixAfterWakeS`, `firstWarnAfterWakeM`, `maxGapSeconds`), every alert
with level, distance, speed, late, cross-track and the outcome of each sink, every sink failure (including a
car-surface update the system dropped, read back after sending), every feed result. The log is one JSON object per
line, rotated at 2,000 lines by keeping the newest 1,000, exportable, wipeable. A self-test pushes a synthetic radar
600 m ahead through the real engine and the real sinks. A plain notification at most once per 24 h when the app is
red and closed.

The status screen has twelve rows (location, Always session, background launches, parked fence, significant
change, data, background refresh, notifications, motion, voice, files, last drive), each ok, amber or
red by the rules in `Sources/RadaresCore/Health/HealthReport.swift`, with a positive and a negative test each.

## 10. The route vectors: how the Kotlin port runs them

`Tests/RadaresCoreTests/Fixtures/feed-sample.geojson` is a 254-feature slice of the live feed (built by
`scripts/make-fixture.py`); `Tests/RadaresCoreTests/Fixtures/vectors/*.json` are drives over it (built by
`scripts/make-vectors.py`, whose expectations come from the rules above in Python, not from the Swift engine). The
Kotlin tests load the same two things unchanged and must produce the same events.

A vector:

```json
{
  "name": "a2-120kmh-ne",
  "description": "...",
  "locale": "es-ES",
  "negativeControl": false,
  "fixes": [{"t": "2026-10-07T10:00:01+02:00", "lat": 41.29, "lon": -1.97, "speed": 33.33, "course": 60.0, "accuracy": 5.0, "stationary": false}],
  "expected": [
    {"kind": "warn", "level": "full", "radar": "dgt-CABINACINEMOMETRO_120001", "distance": 820.0, "tolerance": 40, "late": false, "opposite": false, "spoken": "Radar fijo a 800 metros, sentido Zaragoza."},
    {"kind": "passed", "radar": "dgt-CABINACINEMOMETRO_120001"}
  ],
  "snapshots": [{"fixIndex": 156, "stretch": "dgt_invive-Tramo_Invive_344", "remainingMetres": 7100, "tolerance": 60, "avgKmh": 100, "avgTolerance": 3, "phase": "insideStretch"}]
}
```

Procedure, per vector: decode the fixture into the store; create an engine with an empty ledger and the vector's
locale; feed every fix in order, collecting the events; after the fix at each `snapshots[].fixIndex` read the
snapshot and check the listed fields within their tolerances; then compare the collected events with `expected` in
order. `kind` is one of `warn`, `passed`, `stretchEntered`, `stretchExited`, `driveEnded`; `level` is `full` or
`visual` (a `stretchEntered` is always full); `distance` is checked within `tolerance` (default 40 m); `late`,
`opposite` and `spoken` are checked when present; a `warn` with `level: visual` and a silent `stretchExited` must
carry no sentence; `exitReason` is one of `farGate`, `distance`, `time`, `driveEnd` and rides on the
`stretchExited` event itself. Any difference fails the
vector. A vector with `negativeControl: true` is deliberately wrong and the suite must assert that the engine's
output differs from it: that is the proof the harness can fail. A test suite that executes zero tests fails.

Every "must not fire" vector has a "must fire" twin on the same radar: `leon-50kmh-tomorrow` / `leon-50kmh-today`,
`a2-parallel-150m` and `a2-behind` / `a2-head-on-90kmh`, `a2-no-course-2mps` / `a2-no-course-20mps`,
`a2-uturn-5min` / `a2-uturn-11min-3km`, `osm-bearing-opposite` / `osm-bearing-same`.

Budgets: ingest under 10 ms per fix on a 4,500-feature store; decode of a feed-sized file under 500 ms.

## 11. The legal line

The app warns from published positions only. Spain's Reglamento General de Circulación art. 18.3 bans detectors and
jammers and excludes "los mecanismos de aviso que informan de la posición de los sistemas de vigilancia del tráfico".
No port may sense, receive or interfere with a radar signal. Every radar keeps the `source` and `attribution` the
feed gives it, shown verbatim.
