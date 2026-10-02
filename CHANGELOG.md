# Changelog

## 0.2.0 (2026-10-02)

Covers all of Spain, and keeps warning when a source fails or a week has no list.

**Changed, read before updating**

- The blueprint has a new required input, **Phones**. An automation made from the 0.1.0 blueprint
  shows as unavailable after you re-import it, until you pick its phones. Steps in
  [Getting started](docs/getting-started.md).
- `RADARES_FIXED_RADIUS` and `RADARES_STREET_RADIUS` default to `auto`: the radius follows the road's
  speed limit, so most zones are larger than before. A number keeps a fixed radius.
- The service no longer refuses to sync above 400 zones. `RADARES_MAX_ZONES` (default 1000) keeps the
  radars that matter most and leaves the rest out.
- Days are counted in Spanish time, whatever the container's time zone.

**Added**

- 13 sources behind one registry: DGT fixed radars and mobile-radar stretches, OpenStreetMap, Catalonia,
  the Basque Country, Navarra, Madrid, Salamanca, Donostia, and the police lists of Murcia and León.
  `RADARES_PROVINCES` and `RADARES_SOURCES` choose among them. See [Sources](docs/sources.md).
- The blueprint alerts Android phones as well as iPhones, and triggers on the phone's location tracker,
  so it catches the entries the iPhone app drops. One alert per phone and radar within a cooldown.
- A street from a police list keeps its zones after its period ends, silent, and alerts again when it
  is announced again. The phone does not have to reload zones every week.
- The speed limit in the alert title, and a limit lookup in OpenStreetMap for radars whose source gives
  none.
- A failed source reuses its last good result and never costs its zones. `/metrics` and `/healthz` on
  `RADARES_METRICS_PORT` report sources that are down, a missing weekly list and streets left without a
  zone, with Prometheus rules in [Alerting](docs/alerting.md).
- A published feed with a map, built every 6 hours, and its data licence in
  [LICENSE-DATA.md](LICENSE-DATA.md).

**Fixed**

- An Overpass error answer is no longer cached as if it were data.
- Tests run on the Python the Docker image ships.

## 0.1.0 (2026-09-30)

First release: DGT fixed radars, OpenStreetMap speed cameras and the weekly mobile-radar list of
Murcia's Policía Local as passive Home Assistant zones, with a blueprint that notifies the phone that
enters one.
