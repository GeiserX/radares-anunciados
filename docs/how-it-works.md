# How it works

Every hour the service collects the published radars, turns each into a circle, and makes the radar
zones in Home Assistant match that list. The iOS companion app does the alerting.

## Sources

| Source | How it is read | Refreshed |
|---|---|---|
| DGT fixed radars and average-speed sections | the [DGT NAP](https://nap.dgt.es/dataset/radares-fijos-dgt) DATEX II file, filtered by province | daily |
| OpenStreetMap `highway=speed_camera` | one Overpass query over the bounding boxes of the selected provinces | daily |
| Murcia's Policía Local weekly list | this week's article in La Opinión de Murcia (Murcia Actualidad as a fallback), found through the paper's sitemap | hourly, cached for the week |

`RADARES_PROVINCES` picks the area by INE province code (`30` is Murcia, the default), or `all`. A
radar whose source knows its province is kept only in a selected one, and a city's list is fetched
only when its province is selected. OpenStreetMap is searched by a bounding box per province, never
by an Overpass area lookup, which answers 504 under load. `all` is the 52 boxes of the 50 provinces,
Ceuta and Melilla, so it reaches the Balearics and the Canaries too.

A DGT average-speed section is a zone at each end, and the feed also carries it as a line from one end
to the other. Lines never become zones: a stretch tens of kilometres long is no place for a circle.

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
3. Only the stretch near the district is kept, then covered with circles that overlap, so a car
   anywhere on it is inside one. The circles are sized by the street's limit in OpenStreetMap, the
   one on most of the stretch (see below).

A street or district it can't find is skipped and logged, never guessed. The "Radares actualizados"
notification names it and [`/metrics`](alerting.md) exports it, so you know that street has no
warning. Over five real weeks (26 streets) one was skipped: "Carril Molino Batán", which
OpenStreetMap only has as "Camino del Batán".

## How big a zone is

A real iPhone reports that it entered a region about 200 m past the edge, and some 20 s later. A zone
has to reach that far ahead of the radar, or the alert comes after the car has passed it. With the
default `auto`:

| Radar | Radius | At 120 km/h | At 50 km/h |
|---|---|---|---|
| fixed radar, end of a section | 200 m + 40 s at the limit | 1,533 m | 756 m |
| circle along an announced street | 200 m + 20 s at the limit | 867 m | 478 m |

A street is many circles in a row, so each one needs less lead. When the source gives no limit, the
road decides: 120 km/h on a motorway (`A-`, `AP-`), 90 on any other road, 50 on an announced street.
When the limit is known it goes in the zone name, which is the alert's title: "Radar fijo A-7 km 580.3
(límite 100)". A number in `RADARES_FIXED_RADIUS` or `RADARES_STREET_RADIUS` replaces `auto` with a
fixed radius. No zone is ever under 100 m, which would cost the app three of its 20 regions.

## Why 20 zones is enough

iOS lets one app watch at most 20 regions. The companion app loads every Home Assistant zone, keeps the
20 nearest to its last position, and picks again after every location event
([`ZoneManagerRegionFilter.swift`](https://github.com/home-assistant/iOS/blob/main/Sources/App/ZoneManager/ZoneManagerRegionFilter.swift)).
So the service loads the radars and the phone chooses.

That choice gets slower with more zones: one pass of the app's filter took 21 ms at 1,000 zones and
316 ms at 5,000 on an Apple-silicon core, and it runs on every location event. So the service loads at most
`RADARES_MAX_ZONES` zones, 1,000 by default. With more radars than that it keeps, in this order: the
streets of a list in force this week, the fixed and section radars nearest to Home Assistant's home,
then dormant streets, the most recently announced first. The rest get no zone. It logs how many and
exports `radares_zones_left_out`.

## Zones that don't change presence

Every radar zone is *passive*. Home Assistant never sets a person's state to a passive zone, so
`home` / `not_home` automations behave as before. The app still watches passive zones and fires
`ios.zone_entered`, which the [blueprint](../blueprints/radar_zone_alert.yaml) turns into the alert.

The service only touches zones whose name starts with "Radar" and whose icon is `mdi:camera-timer`
or `mdi:camera-off`. Any other zone is left alone, whatever its icon or name.

## A street after its week

A street from a weekly list keeps its zones after the week ends, for `RADARES_DORMANT_WEEKS` (26 by
default). They keep the same name and the same circles; only the icon changes, to `mdi:camera-off`.
The blueprint alerts on `mdi:camera-timer` only, so a dormant zone is silent. When the police announce
the street again, its zones get `mdi:camera-timer` back.

The icon is changed in place, on the same zone. Deleting and creating it would give the zone a new id,
and the phone would keep reporting the old one until the app is next opened. Police lists repeat
streets, so most weeks the zones stay and only icons change. The cache folder keeps the circles of every street announced in
the last `RADARES_DORMANT_WEEKS` weeks. `0` turns this off: a street's zones go when its week ends.

## How the phone gets new zones

The iOS app stores zones only while it is open on screen, and only when a zone or person changes at
least 15 s after the last change it stored. A sync that creates 50 zones in one burst lands only the
first. So after a change the service does two things:

1. It sends "Radares actualizados" to the phones in `RADARES_NOTIFY`. Tapping it opens the app, which
   loads the whole list.
2. 20 s later it moves one radar zone by 1 cm, a real change Home Assistant announces, so an app that
   is already open stores the whole set. 1 cm is below the 6 decimals the service compares, so the next
   sync sees no difference. Repeated touches move the zone back and forth, never further.

An icon-only change needs nothing on the phone, so it does not notify.

## When a source is down

Downloads are cached. If a refresh fails, the last copy is used. Each source's last good result is
kept in the cache folder too: when a source fails, its last good result is used and logged, so its
zones stay. A source that never answered adds nothing. `/metrics` exports, per source, whether it
answered (`radares_source_up`) and how old its data is (`radares_source_data_age_seconds`). A run
fails only when Home Assistant does. Then Home Assistant keeps the previous zones and the next run
tries again.

## The legal line

Everything comes from published lists and maps. [RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18)
bans radar detectors and jammers and excludes "los mecanismos de aviso que informan de la posición de
los sistemas de vigilancia del tráfico". Nothing here senses a radar signal. Data from commercial radar
apps is not used: their terms forbid extracting it, and EU database law protects it.
