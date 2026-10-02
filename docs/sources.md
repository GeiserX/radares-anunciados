# Sources

Every radar in the feed keeps the source it came from and that source's attribution. `RADARES_SOURCES`
picks sources by key (default: all of them), and a source that covers none of the selected provinces is
skipped. A source marked "yes" under Spanish IP answers only to requests from a Spanish address. Run the service
from Spain to use it. Anywhere else that source shows as down and keeps its last good result.

| Key | What it gives | Publisher | Licence | Cadence | Spanish IP |
|---|---|---|---|---|---|
| `dgt` | Fixed and average-speed section radars on the roads DGT polices: position, road, km, direction. Each fetch also reads the file's `Last-Modified` and warns once it is 30 days old | Dirección General de Tráfico, [NAP dataset radares-fijos-dgt](https://nap.dgt.es/dataset/radares-fijos-dgt), DATEX II | Creative Commons Attribution, as the NAP page states it with no version; recorded as CC BY 4.0 | downloaded daily; the file last changed on 18 Dec 2025 | no |
| `dgt_invive` | About 1,330 stretches of conventional road where DGT runs mobile radars, in 43 provinces (none in Catalonia or the Basque Country): road, km range, both ends. A line in the feed; zones along the road only with `RADARES_STRETCH_ZONES=on` and a province list | Dirección General de Tráfico, [NAP dataset tramos-invive](https://nap.dgt.es/es/dataset/tramos-invive), DATEX II | Creative Commons Attribution, as the NAP page states it with no version; terms of use https://www.dgt.es/contenido/aviso-legal/. Road geometry: ODbL 1.0 | NAP updates it every 4 months; downloaded daily; road geometry from OpenStreetMap cached 90 days | no |
| `osm` | Speed cameras mapped as [`highway=speed_camera`](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dspeed_camera), with limit and direction when tagged. A camera within 150 m of an official radar is dropped as a copy | OpenStreetMap contributors | ODbL 1.0 | daily | no |
| (limit lookup) | The `maxspeed` of the road under each radar whose source gives no limit, which sets the radius. Not a radar source | OpenStreetMap contributors | ODbL 1.0, added to the attribution of each radar it sets | each position asked again after 30 days; the old answer stays if that fails | no |
| `murcia` | Murcia's Policía Local weekly mobile-radar list: street and district, placed on the map from OpenStreetMap | Ayuntamiento de Murcia, as La Opinión de Murcia prints it (Murcia Actualidad as a fallback) | no reuse terms published. Geometry: ODbL 1.0 | weekly | no |
| `sct` | Fixed radars and the cameras of section radars in Catalonia (provinces 08, 17, 25, 43): road, km, speed limit; no direction | Servei Català de Trànsit, [radars.txt](https://transit.gencat.cat/web/.content/documents/seguretat_viaria/radars.txt) | Llicència oberta d'ús d'informació – Catalunya; the attribution carries the file's last update date | republished irregularly (last on 17 Sep 2026); downloaded daily | no |
| `sct_remolc` | The published spots where a trailer radar can stand in Catalonia: road, km, speed limit | Servei Català de Trànsit, [radars-remolc.txt](https://transit.gencat.cat/web/.content/documents/seguretat_viaria/radars-remolc.txt) | Llicència oberta d'ús d'informació – Catalunya | republished irregularly; downloaded daily | no |
| `euskadi` | Fixed booths and section radars of the Basque Country (Araba, Gipuzkoa, Bizkaia), with speed limits | Gobierno Vasco, Dirección de Tráfico (Trafikoa) | no reuse terms published; the [euskadi.eus legal notice](https://www.euskadi.eus/informacion/-/informacion-legal) reserves the content to the Basque Government | daily | yes |
| `navarra` | Fixed radars of the Navarra traffic viewer. The ones the DGT file already lists (same road, within 0.5 km) are left to `dgt`, so it adds only what DGT lacks | Gobierno de Navarra, Visor de Tráfico | no reuse terms published; the [navarra.es legal notice](https://www.navarra.es/es/aviso-legal) reserves the content to the Government of Navarra | daily | yes |
| `donostia` | Municipal fixed radars of Donostia / San Sebastián, with speed limits | Ayuntamiento de Donostia / San Sebastián, GeoDonostia map layer 41 | no reuse terms published | daily | no |
| `donostia_movil` | Donostia's mobile-radar plan for the day: the day's streets as circles along the council map's lines, valid that day only | Ayuntamiento de Donostia / San Sebastián, ["Ubicación del radar móvil"](https://www.donostia.eus/info/ciudadano/radar_movil.nsf/fwHome?ReadForm=&idioma=cas&id=A434305381910) | no reuse terms published | hourly | no |
| `madrid` | Madrid city fixed and section radars, one per camera site, with limit and direction; no mobile radars | Ayuntamiento de Madrid, [datos.madrid.es dataset 300049](https://datos.madrid.es/dataset/300049-0-radares-fijos-moviles) | CC BY 4.0, cited as "Origen de los datos: Ayuntamiento de Madrid" with the date of the last update | updated occasionally; downloaded daily | no |
| `salamanca` | Salamanca city fixed radars with limits, and section radars as lines | Ayuntamiento de Salamanca, [Radares Municipales](https://opendata.aytosalamanca.es/datosabiertos/catalogo/dataset/radares-fijos) | GNU Free Documentation License, as the dataset states it; the portal's terms add data unaltered, source cited, date of last update given | updated occasionally; downloaded daily | no |
| `leon` | León's mobile radars for every day of the month: 5 streets a shift, two shifts a day, each with its limit, valid on its own day and placed inside León's municipal border | Ayuntamiento de León, monthly post; for days no post covers, the weekly article of [iLeón](https://ileon.eldiario.es) | Ayuntamiento de León: no reuse terms published (its portal reserves reproduction except for personal use). iLeón: CC BY-NC 4.0. Geometry: ODbL 1.0 | monthly (council), weekly (iLeón) | yes |
| `barcelona_multas` | Where Barcelona's speed cameras fined in the newest quarter of the city's traffic fines, one zone per place. A place that fined on more than half the quarter's days is a fixed camera; one that fined on fewer, but on 2 days or more, is where a mobile or temporary radar stood (kind `mobile_recurring`), named with its count, such as "(12 días en 92)". A place that fined on a single day gets no zone (5 of 53 in the last quarter of 2025) | Ajuntament de Barcelona, Institut Municipal d'Hisenda, [Open Data BCN dataset denuncies_sancions_transit_bcn_detall](https://opendata-ajuntament.barcelona.cat/data/es/dataset/denuncies_sancions_transit_bcn_detall), read through its datastore SQL API | CC BY 4.0, cited as "Fuente de los datos: Ayuntamiento de Barcelona" with the date of the last update; each radar's attribution names its quarter | quarterly, about nine months behind. On 2 Oct 2026 the newest quarter was October to December 2025. Checked weekly | no |
| `madrid_multas` | Places where Madrid's mobile radars fined in 2 or more of the last 6 months (kind `mobile_recurring`), at the street number the fines name, placed on OpenStreetMap's house numbers inside Madrid's municipal border. A number not mapped takes the nearest mapped one on the same side, at most 10 numbers away; a place with neither is skipped and logged. From September 2025 to February 2026 it found 124 places; 33 recurred, 18 went to their own number, 8 to a neighbouring one and 7 were skipped | Ayuntamiento de Madrid, [datos.madrid.es dataset 210104](https://datos.madrid.es/dataset/210104-0-multas-circulacion-detalle) | CC BY 4.0, cited as "Origen de los datos: Ayuntamiento de Madrid" with the date of the last update; each radar's attribution names its months. Geometry: ODbL 1.0 | monthly, about seven months behind. On 2 Oct 2026 the newest month was February 2026. Checked weekly, and each month's 60 MB file is read once | no |

## Gaps we know about

- The DGT fixed-radar file has not changed since 18 Dec 2025, while DGT's own PDF list is newer. Radars
  added since then are missing unless OpenStreetMap maps them.
- `radars.txt` ships rows with broken coordinates. On 1 Oct 2026 that was 17 of 247 rows, 13 of them
  section cameras. The source skips them and never guesses a fix. If a file loses more than a third of
  its rows, the source refuses it and keeps the last good result.
- Catalonia's table of mobile-radar stretches gives a road and a km range only. Placed from
  OpenStreetMap's km markers, 1 point in 9 landed more than 300 m off, and up to 20 km off where one
  road number carries two km sequences. We don't draw it. Its section-radar table gives a road and a
  town, no position.
- With `RADARES_SOURCES=navarra` and no `dgt`, the Navarra radars DGT lists get no zone.
- Speed limits from the limit lookup make the feed carry ODbL data even for a DGT-only setup.
- The fines sources run months behind, about nine for `barcelona_multas` and seven for `madrid_multas`.
  They show where radars stood then, not where one stands today. Each radar's attribution, which the
  map shows, names the period.
- A Barcelona camera that starts or stops within a quarter counts as a mobile site for that quarter: the
  Ronda del Mig cameras fined every day from 20 Nov 2025, 41 to 43 days of 92.
- A Madrid place that `madrid_multas` cannot place is logged only. Unlike a police list's street, it is
  not exported in `/metrics` nor named in the notification.

## Checked, nothing usable

These publish no radar positions or schedule we can read, or publish them in a form we cannot use.

Authorities:

- DGT's PDF "Puntos y tramos de control de velocidad", on its
  [enforcement page](https://www.dgt.es/conoce-el-estado-del-trafico/vigilancia-y-control/equipos-y-tramos-de-vigilancia/index.html),
  gives road and km only, no coordinates, and its terms forbid reuse.
- DGT's live incident feed and its etraffic map: no radar positions.
- Basque traffic API and Open Data Euskadi: no radars. Trafikoa's campaign page gives dates only.
- Regional open-data portals of the Comunitat Valenciana, the Comunidad de Madrid, Andalucía, Aragón,
  Castilla y León, Galicia and Canarias: no radar dataset.
- Road owners outside Catalonia, the Basque Country and Navarra (Xunta, cabildos, consells,
  diputaciones) publish speed-limit signs, not radars. DGT polices their interurban roads, and its two
  files above cover them.

Cities, north and centre:

- Zaragoza, Valladolid, Logroño, Bilbao: campaign notices with no streets.
- Vitoria-Gasteiz, Palencia, Majadahonda, Albacete: they say on purpose that the radar is not announced.
- Burgos: a 2018 list of ten streets where the mobile radar may stand, no schedule.
- Zamora: a 2016 list of candidate points, no schedule.
- Ponferrada: streets per day in prose, only during DGT campaign weeks, in the press.
- Pamplona: the fixed-radar page refuses automated requests; no mobile schedule.
- Gijón, Oviedo, Avilés, Santander, Torrelavega, Barakaldo, Getxo, Huesca, Teruel, Segovia, Soria,
  Ávila: nothing, or fixed-radar news only.
- Galicia (A Coruña, Vigo, Ourense, Lugo, Pontevedra, Santiago, Ferrol): fixed-radar news only.
- The Comunidad de Madrid towns (Móstoles, Alcalá, Fuenlabrada, Leganés, Getafe, Alcorcón, Torrejón,
  Parla, Alcobendas, Las Rozas, San Sebastián de los Reyes, Pozuelo, Rivas, Coslada, Valdemoro,
  Aranjuez): nothing.
- Castilla-La Mancha (Toledo, Talavera, Ciudad Real, Guadalajara, Cuenca, Puertollano) and Extremadura
  (Badajoz, Cáceres, Mérida, Plasencia): campaign notices only.

Cities, Mediterranean, south and islands:

- Cartagena: a weekly street list on the council site from 2019 to May 2021, stopped since.
- Molina de Segura: weekly posts on social networks only. Lorca: nothing.
- Santa Cruz de Tenerife and Las Palmas de Gran Canaria: the day's streets as posts on X only, which we
  cannot read.
- València, Alicante, Castelló, Granada, Barcelona, Lleida, Terrassa, Sabadell: fixed radars in one-off
  press releases, no dataset and no mobile schedule. OpenStreetMap maps most of them.
- Málaga: open data has red-light cameras only.
- Huelva, Jaén, Algeciras, Chiclana, Telde, Tarragona, Melilla, Eivissa / Sant Josep, Maó, Ciutadella:
  DGT campaign weeks, usually with no streets.
- Elche, Torrevieja, Orihuela, Benidorm, Gandia, Torrent, Paterna, Sagunt, Sevilla, Córdoba, Almería,
  Cádiz, Jerez, Marbella, Dos Hermanas, San Fernando, Roquetas, El Ejido, the Costa del Sol towns,
  Motril, Linares, Palma, La Laguna, Arona, Ceuta, Reus, Girona, L'Hospitalet, Badalona, Mataró,
  Santa Coloma: nothing.
