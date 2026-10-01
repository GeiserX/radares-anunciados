# How it works

Every hour the service collects the published radars, turns each into a circle, and makes the radar
zones in Home Assistant match that list. The Home Assistant companion app (iOS or Android) reports when
the phone enters a zone, and the [blueprint](../blueprints/radar_zone_alert.yaml) sends the alert.

## Sources

| Source | How it is read | Refreshed |
|---|---|---|
| DGT fixed radars and average-speed sections | the [DGT NAP](https://nap.dgt.es/dataset/radares-fijos-dgt) DATEX II file, filtered by province | daily |
| OpenStreetMap `highway=speed_camera` | one Overpass query over a bounding box | daily |
| Murcia's Policía Local weekly list | this week's article in La Opinión de Murcia (Murcia Actualidad as a fallback), found through the paper's sitemap | hourly, cached for the week |

An OpenStreetMap camera within 150 m of a DGT radar is the same camera mapped twice, so it's dropped.
Two radars at the same spot become one zone. The DGT lists both directions of a section with the same
two ends, and the phone has no slots to waste.

The police post the list on X as an image. The press prints it as text: one street and district per
line, such as `Cno. Tiñosa, RM-F6, Los Dolores`. The first part is the street and the last the district.

## From a street name to circles

Murcia has a dozen streets called Avenida Juan Carlos I, so a name alone is not enough.

1. Overpass finds each district, as a place node or a district boundary. "Santiago Zaraiche" in the
   press matches "Santiago y Zaraiche" in OpenStreetMap.
2. Overpass finds the ways with the street's name within 5 km of that district. Names are compared
   without accents, articles or "Don": "Avenida Juan de Borbón" matches "Avenida Don Juan de Borbón".
   When nothing of the stated type is near, another type is accepted. The press wrote "Calle
   Campillo" for what OpenStreetMap maps as "Carril Campillo".
3. Only the stretch near the district is kept, then covered with 300 m circles that overlap, so a car
   anywhere on it is inside one.

A street or district it can't find is skipped and logged, never guessed. The "Radares actualizados"
notification names it and [`/metrics`](alerting.md) exports it, so you know that street has no
warning. Over five real weeks (26 streets) one was skipped: "Carril Molino Batán", which
OpenStreetMap only has as "Camino del Batán".

## How many zones a phone watches

iOS lets one app watch at most 20 regions. The companion app loads every Home Assistant zone, keeps the
20 nearest to its last position, and picks again after every location event
([`ZoneManagerRegionFilter.swift`](https://github.com/home-assistant/iOS/blob/main/Sources/App/ZoneManager/ZoneManagerRegionFilter.swift)).
So the service loads all the radars and the phone chooses. A zone under 100 m costs the app three
regions, so no radar zone is smaller than 100 m.

Android lets one app watch at most 100 geofences, and the companion app does not pick the nearest: it
takes Home Assistant's zones sorted by entity id and stops at 100. A radar outside those 100 fires no
`android.zone_entered`. The blueprint does not depend on that event: Home Assistant itself works out
which zones each location update falls in, so with high accuracy mode on (a location every 5 seconds)
every radar zone alerts, whatever the count.

## Zones that don't change presence

Every radar zone is *passive*. Home Assistant never sets a person's state to a passive zone, so
`home` / `not_home` automations behave as before. Passive zones still count everywhere the alert needs
them: both apps watch them and fire `ios.zone_entered` or `android.zone_entered`, and each phone's
location tracker lists them in its `in_zones` attribute.

## How the alert fires

The blueprint listens to three things for each phone you pick:

- the phone's location tracker, whose `in_zones` gains the radar zone;
- `ios.zone_entered`, which the iPhone sends about 0.25 s before the tracker update;
- `android.zone_entered`, sent from the same GPS fix as the tracker update, in either order.

The tracker is the one that never misses. The app events are lost in cases we measured: iOS drops the
event when it relaunches a terminated app for the region, and fires none for a zone that joins its 20
while the phone is already inside; Android fires none for a zone outside its 100. In all of those the
tracker still lists the zone. The events stay as triggers because, when they do arrive, they can be
first.

Only zones with the icon `mdi:camera-timer` alert. A zone the service keeps but marks as not in force
(`mdi:camera-off`) never alerts. If it comes into force while the phone is inside it, the phone is
alerted at its next location update.

Each phone is alerted through its own notify action, `notify.mobile_app_<device name>`, taken from the
device registry. The notification depends on the phone:

| | iPhone | Android |
|---|---|---|
| Normal | sound, interruption level `time-sensitive` (shows through Focus) or `active` | channel `Radares`, importance high, priority high, `ttl: 0`: a heads-up notification delivered at once |
| Critical | iOS critical alert: full volume, also in silent mode and Do Not Disturb | channel `alarm_stream`: the app plays the notification on the alarm stream, at the alarm volume, also in silent mode |

Android has no exact match for an iOS critical alert. The alarm stream is the closest: it rings when
the ringer is off, at whatever the alarm volume is set to.

The service only touches zones with the icon `mdi:camera-timer` whose name starts with "Radar". It
refuses to sync more than 400 zones, so a broken parser can't flood Home Assistant.

## One alert per street

A street from a police list is a row of overlapping circles named `Radar anunciado …`, and an
average-speed section is a circle at each end named `Radar de tramo …`. The phone enters each circle
in turn, so the blueprint treats each of these names as one radar: it alerts a phone once and then
ignores that name for that phone until the cooldown ends (10 minutes by default).

Every other zone is its own radar, even when its name is shared. OpenStreetMap cameras without a road
and kilometre are all called `Radar (límite 50)` or plain `Radar`, and they are different cameras, so
the blueprint tells them apart by zone, not by name. A source that draws one radar as several circles
must use one of the two prefixes above, or each circle alerts on its own. A different radar, or a
different phone, is alerted at once.

The blueprint remembers without a helper. When it alerts, it creates a scene named after the phone and
the radar, such as `scene.radares_anunciados_<device id>_radar_anunciado_calle_mayor`: the marker. An
entry whose marker exists is skipped. Once a marker is older than the cooldown and its phone has left
that radar, a template trigger deletes it. No run waits: each run checks, marks and notifies, and runs
go one at a time, so an app event and a tracker update for the same entry alert once.

Comparing the tracker's previous and new `in_zones` by name is not enough on its own, which is why the
markers stay:

- The iPhone's event arrives before the tracker update. Without a marker, the event alerts and then the
  tracker update, which gains the zone, alerts again.
- The two ends of a section are kilometres apart, so the phone is in no radar zone between them.
- Above 100 zones the Android app re-registers its geofences on every sensor pass and fires
  `android.zone_entered` again for a zone you are already in.

Two costs come with it:

- Home Assistant forgets these scenes on restart. On start the blueprint marks every radar a phone is
  inside, so a restart mid-street doesn't alert again, and the next radar alerts as usual.
- The blueprint can't tell whether the push reached the phone. The mobile app integration logs a
  failed push (a timeout or an error from the push service) and carries on, so the blueprint counts it
  as sent. If the alert for the first circle of a street is lost, the rest of that street stays quiet
  until the cooldown ends.

## When a source is down

Downloads are cached. If a refresh fails, the last copy is used. If a whole run fails, Home Assistant
keeps the previous zones and the next run tries again.

## The legal line

Everything comes from published lists and maps. [RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18)
bans radar detectors and jammers and excludes "los mecanismos de aviso que informan de la posición de
los sistemas de vigilancia del tráfico". Nothing here senses a radar signal. Data from commercial radar
apps is not used: their terms forbid extracting it, and EU database law protects it.
