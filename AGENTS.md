# AGENTS.md: radares-anunciados

An open feed of the speed radars announced in Spain, merged into one GeoJSON file, plus a Home Assistant
side that turns the radars near you into zones so the Home Assistant companion app alerts you as you
drive near one. Python managed with uv, shipped as a Docker image on Docker Hub and GHCR, CI on GitHub
Actions.

## Data sources

Every radar in the feed keeps its source and that source's license, and the feed credits each source.

| Key | What it gives | License |
|---|---|---|
| `dgt` | DGT fixed and section radars, [NAP](https://nap.dgt.es/dataset/radares-fijos-dgt) DATEX II | Creative Commons Attribution (NAP, no version) |
| `dgt_invive` | DGT mobile-radar stretches, [NAP](https://nap.dgt.es/es/dataset/tramos-invive); lines, zones opt-in (`RADARES_STRETCH_ZONES`) | same |
| `osm` | [`highway=speed_camera`](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dspeed_camera) nodes and enforcement relations; also the speed-limit lookup (`osm_limits.py`) | ODbL 1.0 |
| `osm_notes` | open OSM notes reporting a camera: kind `reported`, unconfirmed, never a zone; off by default, the published feed turns it on | ODbL 1.0 |
| `murcia` | Policía Local weekly list, through the press | no reuse terms published |
| `sct`, `sct_remolc` | Servei Català de Trànsit fixed, section and trailer radars | Llicència oberta d'ús d'informació – Catalunya |
| `euskadi`, `navarra` | Basque and Navarra government fixed radars (Spanish IP only) | no reuse terms published |
| `donostia`, `donostia_movil` | Donostia fixed radars and its daily mobile-radar streets | no reuse terms published |
| `madrid`, `salamanca` | city open data, fixed and section radars | CC BY 4.0; GNU FDL |
| `leon` | León's monthly mobile-radar post, iLeón as a fallback (Spanish IP only) | no reuse terms published; iLeón CC BY-NC 4.0 |

Cadence, publishers and the places that publish nothing usable: [`docs/sources.md`](docs/sources.md).
Check a publisher's reuse terms before adding it, and record them in its `Source.licence`.

## The legal line

The project warns from published positions only, which is what keeps it legal in Spain.
[RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18) bans radar jammers and radar
detectors in a vehicle and excludes "los mecanismos de aviso que informan de la posición de los sistemas de
vigilancia del tráfico". Every feature reads published lists and maps; a feature that senses, receives or
interferes with a radar signal is out of scope, whoever asks for it.

## Layout

- `src/radares_anunciados/sources/`: one module per source (key in the table above). Each exposes
  `SOURCE = Source(key, fetch, attribution, licence, spanish_ip, max_age_s, provinces, official)` and
  is listed once in `sources/__init__.py`. `official=False` marks a crowd map (OSM): `feed.merge` drops
  its camera within 150 m of a radar from an official source. `fetch(Context)` returns a
  `SourceResult` (radars, stretches, weekly lists) and raises on any failure; the registry then reuses
  its last good result. Contract in `sources/base.py`.
- `model.py`: `Radar`, `Stretch`, `SourceResult`, `today_in_spain`; `provinces.py`: INE codes and
  bounding boxes
- `speed.py`: radius by speed limit; `LOOKUPS` is the hook for a limit lookup; `geo.py`: distances,
  street cover, ETRS89 UTM to WGS84
- `streets.py`: street + district from a police list to circle centres (two Overpass queries);
  `streetnames.py`: abbreviations in police lists ("Avda.", "Pº") expanded
- `osm_limits.py`: the speed limit under a radar whose source gives none, from OpenStreetMap
- `feed.py`: merge, dedupe, dormant streets, GeoJSON; `ha.py`: Home Assistant zone sync over the websocket API
- `store.py`: each source's last good result and the announced streets, in the cache folder
- `metrics.py`: `/metrics` and `/healthz` of `radares run`, standard library only ([`docs/alerting.md`](docs/alerting.md))
- [`blueprints/radar_zone_alert.yaml`](blueprints/radar_zone_alert.yaml): the automation that sends the alert
- [`.github/workflows/feed.yml`](.github/workflows/feed.yml): builds `feed.geojson`, `status.json` and the
  map in [`site/`](site/) every 6 hours and publishes them to GitHub Pages. The data is ODbL
  ([`LICENSE-DATA.md`](LICENSE-DATA.md)); a new source gets a row there in the same change (a test checks).
- [`tests/fixtures/`](tests/fixtures/): real pages and responses, trimmed. Tests never touch the network.
- [`docs/how-it-works.md`](docs/how-it-works.md) explains the design in full.

## Rules that keep it working

- A `reported` point (an OSM note) never becomes a zone (`ha.zoned`) and never drops or replaces
  another radar (`feed.merge`).
- Zones are passive, name starting with "Radar", icon `mdi:camera-timer` (alerts) or `mdi:camera-off`
  (a dormant street, silent). `ha.py` touches no other zone.
- A dormant street changes only its icon, with `zone/update` on the same zone id. Never delete and
  create a zone whose place did not change: the phone would keep the old id.
- Radius never under 100 m: the iOS app splits smaller zones into three regions of its 20.
- At most `RADARES_MAX_ZONES` (1,000) zones. Over it, drop zones in order; never refuse to sync.
- The iOS app loads new zones only in the foreground, and drops a change within 15 s of the last one it
  stored. Every create or delete notifies the phones, and every change is followed 20 s later by a
  1 cm move of one zone, below the 6 decimals a plan compares.
- A failing source never fails the run and never costs its zones. Only Home Assistant fails a run. A
  failed source shows as down in `/metrics` (`net.cached_get` raises on a failed refresh rather than
  hand back an old copy).
- Only a real sync writes the announced-streets history; `sync --dry-run` never does, and `feed` only
  with `--save-history` (the published feed, whose cache no sync shares).
- The day is Spain's (`model.today_in_spain`), never the container's: it runs on UTC, and a per-day
  list starts at Spanish midnight.
- An Overpass answer is cached only once `net.overpass_answer` takes it (`cached_get(validate=...)`):
  Overpass answers 200 with a `remark` when a query runs out of time.
- Overpass by bounding boxes (`provinces.py`), never an area lookup: it answers 504.
- Never send Overpass a name regex over the whole municipality. It answers 504. Look up the districts
  first, then search `around` them.
- La Opinión's street list is `ul.ft-list--primary`. A plain `ft-list` on the same page holds headlines.
- A street or district not found is skipped, never guessed. It is logged, exported as
  `radares_street_skipped` and named in the "Radares actualizados" notification.
- One radar drawn as several circles is named `Radar anunciado …` (police list) or `Radar de tramo …`
  (section). The blueprint alerts once per such name; every other zone alerts on its own, because
  names like OSM's `Radar (límite 50)` repeat across different cameras.

Checks: `uv run ruff check . && uv run ruff format --check . && uv run pytest -q`.
