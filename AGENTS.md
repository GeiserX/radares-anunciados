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

## State

No source code yet. This file grows with the code.
