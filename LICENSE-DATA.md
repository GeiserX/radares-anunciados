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
build, and `updated`, the date the source gives for its last update, when it gives one.

| Source | What it gives | Attribution | Terms |
|---|---|---|---|
| `dgt` | fixed radars and average-speed sections from the [DGT National Access Point](https://nap.dgt.es/dataset/radares-fijos-dgt) | Dirección General de Tráfico, with the file's last update date | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `osm` | `highway=speed_camera` nodes from [OpenStreetMap](https://www.openstreetmap.org/copyright) | © OpenStreetMap contributors | [ODbL 1.0](https://opendatacommons.org/licenses/odbl/1-0/) |
| `murcia` | the weekly mobile-radar list of the Policía Local de Murcia, read in the local press, placed on OpenStreetMap streets | Policía Local de Murcia, and the newspaper it was read in; geometry © OpenStreetMap contributors | the police's list: no licence of its own; reused under Ley 37/2007 (see below); geometry ODbL 1.0 |
| `dgt_invive` | stretches of road where DGT runs mobile radars, from the [DGT National Access Point](https://nap.dgt.es/es/dataset/tramos-invive); road geometry from OpenStreetMap | Dirección General de Tráfico; geometry © OpenStreetMap contributors | Creative Commons Attribution, as the dataset page states it with no version; geometry ODbL 1.0 |
| `sct` | fixed and section radars in Catalonia, from the [Servei Català de Trànsit](https://transit.gencat.cat/ca/seguretat_viaria/cinemometres-fixos-trams-mobils/) | Generalitat de Catalunya. Departament d'Interior i Seguretat Pública. Servei Català de Trànsit, with the file's last update date | Llicència oberta d'ús d'informació – Catalunya |
| `sct_remolc` | the published spots for trailer radars in Catalonia, same publisher | Generalitat de Catalunya. Departament d'Interior i Seguretat Pública. Servei Català de Trànsit, with the file's last update date | Llicència oberta d'ús d'informació – Catalunya |
| `euskadi` | fixed and section radars of the Basque Country | Gobierno Vasco / Eusko Jaurlaritza, Dirección de Tráfico (Trafikoa) | no licence of its own; reused under Ley 37/2007 (see below); [euskadi.eus legal notice](https://www.euskadi.eus/informacion/-/informacion-legal) |
| `navarra` | fixed radars of the Navarra traffic viewer that the DGT file lacks | Gobierno de Navarra, Visor de Tráfico | no licence of its own; reused under Ley 37/2007 (see below); [navarra.es legal notice](https://www.navarra.es/es/aviso-legal) |
| `donostia` | municipal fixed radars of Donostia / San Sebastián | © Donostiako Udala - Ayuntamiento de Donostia / San Sebastián | no licence of its own; reused under Ley 37/2007 (see below) |
| `donostia_movil` | Donostia's mobile-radar streets for the day | Ayuntamiento de Donostia / San Sebastián, ubicación del radar móvil | no licence of its own; reused under Ley 37/2007 (see below) |
| `madrid` | Madrid city fixed and section radars, from [datos.madrid.es](https://datos.madrid.es/dataset/300049-0-radares-fijos-moviles) | Origen de los datos: Ayuntamiento de Madrid, with the dataset's last update date | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| `salamanca` | Salamanca city fixed and section radars, from its [open data portal](https://opendata.aytosalamanca.es/datosabiertos/catalogo/dataset/radares-fijos) | Ayuntamiento de Salamanca, Radares Municipales, with each layer's last update date | GNU Free Documentation License, as the dataset states it; the portal adds: data unaltered, source cited, date of last update given |
| `leon` | León's mobile-radar streets for each day, placed on OpenStreetMap streets | Ayuntamiento de León; on days only iLeón covers, Redacción ILEÓN, obtenido de ILEÓN (ileon.eldiario.es); geometry © OpenStreetMap contributors | the council's list: no licence of its own; reused under Ley 37/2007 (see below); iLeón's articles: CC BY-NC 4.0, of which the feed takes the facts only (see below); geometry ODbL 1.0 |

## Public bodies with no licence of their own

The Basque Government, the Government of Navarra and the councils of Donostia / San Sebastián, Murcia
and León publish their radar lists with no licence attached. The feed reuses them under Spain's law on
the reuse of public-sector information,
[Ley 37/2007, de 16 de noviembre](https://www.boe.es/buscar/act.php?id=BOE-A-2007-19814):

- it covers the documents of the State, regional and local administrations (art. 2.a), and is basic
  legislation, so it applies to all of them (first final provision);
- those documents are reusable, for commercial or non-commercial purposes (art. 4.1);
- reuse is subject to conditions only when they are objective, proportionate, non-discriminatory and
  justified by a public interest, and such conditions are set in a licence (art. 4.2).

Article 8 lists the general conditions a body may attach to reuse. The feed meets them for every
source, with or without a licence:

| Art. 8 | Condition | How the feed meets it |
|---|---|---|
| a | the content, metadata included, is not altered | positions, roads, km, streets, days and limits are published as the source gives them, with street-name abbreviations spelled out. The feed never repairs a position; it skips a record with broken coordinates. The feed adds a radius and, for an announced street, circles along it; street geometry and a limit the source does not give come from OpenStreetMap and are credited to it |
| b | the meaning is not distorted | each record keeps its kind and the days it is valid on; a street whose period has ended is marked `active: false`, never shown as announced |
| c | the source is cited | every feature carries `source` and `attribution`; `status.json` gives each source's attribution and terms |
| d | the date of the last update is given | where the source gives one (the DGT and SCT file dates, the Madrid and Salamanca catalogue dates), each record's attribution carries "actualizado" and the date, and `status.json` gives it as `updated`. For every source, `status.json` gives `data_time`, when its data was read; a daily or weekly list also carries the days it is valid on (`valid_from`, `valid_to`) |
| e, f | personal data | none; the records are places, roads and dates |

The feed does not say or suggest that any source takes part in it or endorses it. Art. 4.9 forbids that
for the State's bodies.

Two lists reach the feed through a newspaper: Murcia's, through La Opinión de Murcia (Murcia Actualidad
as a fallback), and León's, on days the council's own post does not cover, through iLeón, whose
articles are CC BY-NC 4.0. The list itself is the police's or the council's information. The feed takes
its facts (street, district or day, limit), not the article's text, and credits the newspaper as where
the list was read.

## Sources added later

A source added later carries its own attribution and terms in its module (`sources/<key>.py`), in every
feature it adds and in `status.json`; it is added to the table of sources in the same change.

The map tiles on the published page are © OpenStreetMap contributors and are not part of the feed.

## What the feed is

Positions published by the sources above, merged and deduplicated. It warns from published positions
only and is offered as is, with no warranty: a radar can be missing, moved or out of date.
