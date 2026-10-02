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
| `dgt_invive` | stretches of road where DGT runs mobile radars, from the [DGT National Access Point](https://nap.dgt.es/es/dataset/tramos-invive); road geometry from OpenStreetMap | Dirección General de Tráfico; geometry © OpenStreetMap contributors | Creative Commons Attribution, as the dataset page states it with no version; geometry ODbL 1.0 |
| `sct` | fixed and section radars in Catalonia, from the [Servei Català de Trànsit](https://transit.gencat.cat/ca/seguretat_viaria/cinemometres-fixos-trams-mobils/) | Generalitat de Catalunya. Departament d'Interior i Seguretat Pública. Servei Català de Trànsit, with the file's last update date | Llicència oberta d'ús d'informació – Catalunya |
| `sct_remolc` | the published spots for trailer radars in Catalonia, same publisher | Generalitat de Catalunya. Departament d'Interior i Seguretat Pública. Servei Català de Trànsit | Llicència oberta d'ús d'informació – Catalunya |
| `euskadi` | fixed and section radars of the Basque Country | Gobierno Vasco / Eusko Jaurlaritza, Dirección de Tráfico (Trafikoa) | no reuse terms published; the [euskadi.eus legal notice](https://www.euskadi.eus/informacion/-/informacion-legal) reserves the content |
| `navarra` | fixed radars of the Navarra traffic viewer that the DGT file lacks | Gobierno de Navarra, Visor de Tráfico | no reuse terms published; the [navarra.es legal notice](https://www.navarra.es/es/aviso-legal) reserves the content |
| `donostia` | municipal fixed radars of Donostia / San Sebastián | © Donostiako Udala - Ayuntamiento de Donostia / San Sebastián | no reuse terms published |
| `donostia_movil` | Donostia's mobile-radar streets for the day | Ayuntamiento de Donostia / San Sebastián, ubicación del radar móvil | no reuse terms published |
| `madrid` | Madrid city fixed and section radars, from [datos.madrid.es](https://datos.madrid.es/dataset/300049-0-radares-fijos-moviles) | Origen de los datos: Ayuntamiento de Madrid | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `salamanca` | Salamanca city fixed and section radars, from its [open data portal](https://opendata.aytosalamanca.es/datosabiertos/catalogo/dataset/radares-fijos) | Ayuntamiento de Salamanca, Radares Municipales | GNU Free Documentation License, as the dataset states it; the portal adds: data unaltered, source cited, date of last update given |
| `leon` | León's mobile-radar streets for each day, placed on OpenStreetMap streets | Ayuntamiento de León; Redacción ILEÓN, obtenido de ILEÓN (ileon.eldiario.es); geometry © OpenStreetMap contributors | council: no reuse terms published, its portal reserves reproduction except for personal use; iLeón: CC BY-NC 4.0; geometry ODbL 1.0 |
| `barcelona_multas` | places where Barcelona's mobile radars fined, from the city's [traffic-fines open data](https://opendata-ajuntament.barcelona.cat/data/es/dataset/denuncies_sancions_transit_bcn_detall), grouped by place and day | Fuente de los datos: Ayuntamiento de Barcelona, with the quarter and the date of the last update | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `madrid_multas` | places where Madrid's mobile radars fined in two months or more, from the city's [traffic-fines open data](https://datos.madrid.es/dataset/210104-0-multas-circulacion-detalle), placed at their address in the city's [official street register](https://datos.madrid.es/dataset/213605-0-callejero-oficial-madrid) | Origen de los datos: Ayuntamiento de Madrid, with the months and the date of the last update | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

A source added later carries its own attribution and terms in its module (`sources/<key>.py`), in every
feature it adds and in `status.json`; it is added to this table in the same change.

The map tiles on the published page are © OpenStreetMap contributors and are not part of the feed.

## What the feed is

Positions published by the sources above, merged and deduplicated. It warns from published positions
only and is offered as is, with no warranty: a radar can be missing, moved or out of date.
