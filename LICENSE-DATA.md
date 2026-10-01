# Data license

The code in this repository is under [GPL-3.0-or-later](LICENSE). This file covers the data: the
published feed (`feed.geojson`) and its `status.json`.

## The feed is under ODbL 1.0

The feed includes speed cameras mapped in OpenStreetMap, and places announced streets on OpenStreetMap
geometry. That makes it a database derived from OpenStreetMap, so it is offered under the
[Open Database License (ODbL) 1.0](https://opendatacommons.org/licenses/odbl/1-0/).

You may copy, share and adapt it. If you publish it, or a database made from it, you must:

- credit it as "Radares Anunciados, © OpenStreetMap contributors and the sources listed below";
- offer what you publish under the ODbL too, and keep it open (no technical restrictions without an
  unrestricted copy alongside).

## Sources and their attributions

Every feature carries `source` and `attribution` properties, so each record keeps its credit when you
take it out of the feed. `status.json` lists the same attribution and licence for every source in the
build.

| Source | What it gives | Attribution | Terms |
|---|---|---|---|
| `dgt` | fixed radars and average-speed sections from the [DGT National Access Point](https://nap.dgt.es/dataset/radares-fijos-dgt) | Dirección General de Tráfico | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `osm` | `highway=speed_camera` nodes from [OpenStreetMap](https://www.openstreetmap.org/copyright) | © OpenStreetMap contributors | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) |
| `murcia` | the weekly mobile-radar list of the Policía Local de Murcia, as reprinted by the local press, placed on OpenStreetMap streets | Policía Local de Murcia; geometry © OpenStreetMap contributors | the council's list; geometry ODbL 1.0 |

A source added later carries its own attribution and terms in its module (`sources/<key>.py`), in every
feature it adds and in `status.json`; it is added to this table in the same change.

The map tiles on the published page are © OpenStreetMap contributors and are not part of the feed.

## What the feed is

Positions published by the sources above, merged and deduplicated. It warns from published positions
only and is offered as is, with no warranty: a radar can be missing, moved or out of date.
