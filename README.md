<p align="center">
  <img src="docs/images/banner.svg" alt="Radares Anunciados" width="100%">
</p>

<h1 align="center">Radares Anunciados</h1>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/GeiserX/radares-anunciados?style=flat-square" alt="License"></a>
</p>

Radares Anunciados is a Docker service that gathers the speed radars announced in Spain into one open GeoJSON feed. Its Home Assistant side turns the radars near you into zones, so the Home Assistant companion app alerts you when you drive toward one.

## Features

- One GeoJSON feed with every announced radar, each point tagged with its source and license
- The weekly mobile-radar lists that municipal police publish, starting with Murcia's Policía Local
- Fixed DGT radars from the [DGT National Access Point](https://nap.dgt.es/dataset/radares-fijos-dgt), published as DATEX II
- Speed cameras mapped in [OpenStreetMap](https://wiki.openstreetmap.org/wiki/Tag:highway%3Dspeed_camera)
- Home Assistant zones kept in sync with the radars around you, for alerts through the companion app
- Warns from published positions only; it never senses or jams a radar signal

## Quick start

```sh
export HA_URL=https://homeassistant.example.org HA_TOKEN='<long-lived token>'
docker run --rm -e HA_URL -e HA_TOKEN drumsergio/radares-anunciados:0.1.0 sync --dry-run
mkdir -p data && sudo chown 65534:65534 data  # the container runs as nobody
docker run -d --name radares -e HA_URL -e HA_TOKEN -v ./data:/data -e RADARES_CACHE=/data drumsergio/radares-anunciados:0.1.0
```

Then import the [alert blueprint](blueprints/radar_zone_alert.yaml). Full steps in [Getting started](docs/getting-started.md).

## Documentation

- [Getting started](docs/getting-started.md): token, container, blueprint, settings
- [How it works](docs/how-it-works.md): sources, street matching, the 20-zone limit, passive zones
- [Alerting](docs/alerting.md): Prometheus metrics, the health check, alert rules for a failing service

## Data sources

| Source | License |
|---|---|
| Municipal police weekly lists | each council's reuse terms |
| [DGT NAP](https://nap.dgt.es/dataset/radares-fijos-dgt), fixed radars | CC BY 4.0 |
| [OpenStreetMap](https://www.openstreetmap.org/copyright) contributors | ODbL 1.0 |

## Legal

In Spain, [RGC art. 18.3](https://www.boe.es/buscar/act.php?id=BOE-A-2003-23514#a18) bans radar jammers and radar detectors in a vehicle, and excludes from that ban the warning mechanisms that report where traffic enforcement systems are. Radar positions here come only from published lists and maps, so this project is one of those warning mechanisms.

## License

[GPL-3.0-or-later](LICENSE)
