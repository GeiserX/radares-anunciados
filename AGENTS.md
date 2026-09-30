# AGENTS.md: radares-anunciados

An open feed of the speed radars announced in Spain, merged into one GeoJSON file, plus a Home Assistant
side that turns the radars near you into zones so the Home Assistant companion app alerts you as you
drive near one. Python managed with uv, shipped as a Docker image on Docker Hub and GHCR, CI on GitHub
Actions.

## Data sources

Every radar in the feed keeps its source and that source's license, and the feed credits each source.

| Source | What it gives | License |
|---|---|---|
| Municipal police weekly lists (first: Murcia's Policía Local) | mobile radars announced for the week | the council's own reuse terms; check them before adding a city |
| [DGT NAP](https://nap.dgt.es/dataset/radares-fijos-dgt), DATEX II | fixed DGT radars | CC BY 4.0 |
| OpenStreetMap, [`highway=speed_camera`](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dspeed_camera) | community-mapped speed cameras | ODbL (attribution, share-alike on the derived database) |

## The legal line

The project warns from published positions only, which is what keeps it legal in Spain.
[RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18) bans radar jammers and radar
detectors in a vehicle and excludes "los mecanismos de aviso que informan de la posición de los sistemas de
vigilancia del tráfico". Every feature reads published lists and maps; a feature that senses, receives or
interferes with a radar signal is out of scope, whoever asks for it.

## Layout

- `src/radares_anunciados/sources/`: one module per source (`dgt`, `osm`, `murcia`), each returning `Radar`s
- `streets.py`: street + district from a police list to circle centres (two Overpass queries)
- `feed.py`: merge, dedupe, GeoJSON; `ha.py`: Home Assistant zone sync over the websocket API
- [`blueprints/radar_zone_alert.yaml`](blueprints/radar_zone_alert.yaml): the automation that sends the alert
- [`tests/fixtures/`](tests/fixtures/): real pages and responses, trimmed. Tests never touch the network.
- [`docs/how-it-works.md`](docs/how-it-works.md) explains the design in full.

## Rules that keep it working

- Zones are passive, icon `mdi:camera-timer`, name starting with "Radar". `ha.py` touches no other zone.
- Radius never under 100 m: the iOS app splits smaller zones into three regions of its 20.
- The iOS app loads new zones only in the foreground; every change notifies the phones.
- Never send Overpass a name regex over the whole municipality. It answers 504. Look up the districts
  first, then search `around` them.
- La Opinión's street list is `ul.ft-list--primary`. A plain `ft-list` on the same page holds headlines.
- A street or district not found is skipped and logged, never guessed.

Checks: `uv run ruff check . && uv run ruff format --check . && uv run pytest -q`.
