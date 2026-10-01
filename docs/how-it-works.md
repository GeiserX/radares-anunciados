# How it works

Every hour the service collects the published radars, turns each into a circle, and makes the radar
zones in Home Assistant match that list. The iOS companion app does the alerting.

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

A street or district it can't find is skipped and logged, never guessed. Over five real weeks (26
streets) one was skipped: "Carril Molino Batán", which OpenStreetMap only has as "Camino del Batán".

## Why 20 zones is enough

iOS lets one app watch at most 20 regions. The companion app loads every Home Assistant zone, keeps the
20 nearest to its last position, and picks again after every location event
([`ZoneManagerRegionFilter.swift`](https://github.com/home-assistant/iOS/blob/main/Sources/App/ZoneManager/ZoneManagerRegionFilter.swift)).
So the service loads all the radars and the phone chooses. A zone under 100 m costs the app three
regions, so no radar zone is smaller than 100 m.

## Zones that don't change presence

Every radar zone is *passive*. Home Assistant never sets a person's state to a passive zone, so
`home` / `not_home` automations behave as before. The app still watches passive zones and fires
`ios.zone_entered`, which the [blueprint](../blueprints/radar_zone_alert.yaml) turns into the alert.

The service only touches zones with the icon `mdi:camera-timer` whose name starts with "Radar". It
refuses to sync more than 400 zones, so a broken parser can't flood Home Assistant.

## One alert per street

A street is a row of overlapping circles with one name, and an average-speed section is a circle at
each end with one name. The app fires `ios.zone_entered` for each circle, so the blueprint alerts a
phone once per radar name and then ignores that name for that phone until the cooldown ends (10
minutes by default). A different name, or a different phone, is alerted at once.

The blueprint remembers without a helper. When it alerts, it creates a scene named after the phone and
the radar, such as `scene.radares_anunciados_iphone_radar_calle_mayor`, waits for the cooldown and
deletes it. If that scene exists and is younger than the cooldown, the blueprint skips the entry. Each
alert keeps one automation run open for the cooldown, so the automation shows as running while you
drive. Home Assistant forgets these scenes on restart, so a street can alert once more after a
restart.

## When a source is down

Downloads are cached. If a refresh fails, the last copy is used. If a whole run fails, Home Assistant
keeps the previous zones and the next run tries again.

## The legal line

Everything comes from published lists and maps. [RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18)
bans radar detectors and jammers and excludes "los mecanismos de aviso que informan de la posición de
los sistemas de vigilancia del tráfico". Nothing here senses a radar signal. Data from commercial radar
apps is not used: their terms forbid extracting it, and EU database law protects it.
