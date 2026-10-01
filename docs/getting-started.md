# Getting started

You need Home Assistant with the iOS companion app on each phone that should get alerts, and a
machine that runs Docker.

## 1. Create a Home Assistant token

In Home Assistant, open your profile, then **Security → Long-lived access tokens → Create token**.
The service uses it to create, move and delete its radar zones.

## 2. Run the service

```yaml
# docker-compose.yml
services:
  radares-anunciados:
    image: drumsergio/radares-anunciados:0.1.0
    restart: unless-stopped
    environment:
      HA_URL: https://homeassistant.example.org
      HA_TOKEN: ${HA_TOKEN}
      # the phones to tell when the zones change (see step 4)
      RADARES_NOTIFY: notify.mobile_app_phone1,notify.mobile_app_phone2
      RADARES_CACHE: /data
    volumes:
      - ./data:/data
```

The container runs as user 65534, so give it the cache folder first: `mkdir -p data && sudo chown
65534:65534 data`. Then `docker compose up -d` and read the log. The first run creates the zones:

```
INFO Murcia list https://www.laopiniondemurcia.es/murcia/2026/09/28/...: 6 streets
INFO zones: 0 kept, 89 to create, 0 to delete
```

To see what it would do without touching Home Assistant:

```sh
docker compose run --rm radares-anunciados sync --dry-run
```

## 3. Import the alert blueprint

[![Import blueprint](https://my.home-assistant.io/badges/blueprint_import.svg)](https://my.home-assistant.io/redirect/blueprint_import/?blueprint_url=https%3A%2F%2Fgithub.com%2FGeiserX%2Fradares-anunciados%2Fblob%2Fmain%2Fblueprints%2Fradar_zone_alert.yaml)

Or copy [`blueprints/radar_zone_alert.yaml`](../blueprints/radar_zone_alert.yaml) into Home Assistant
by hand. Create one automation from it. When a phone enters a radar zone, that phone gets a
notification titled with the radar. It's marked time-sensitive, so it shows through Focus modes.

A street is several zones with the same name, so each phone gets one alert per radar name and then
stays quiet about that name for the **Cooldown** (10 minutes by default). Another radar, or another
phone, is alerted at once. No helper is needed.

## 4. Open the app once after each change

The iOS app only downloads new zones while it is open on screen. After every change the service sends
"Radares actualizados" to the phones in `RADARES_NOTIFY`; tap it and the new zones load. Until you do,
the phone keeps warning about last week's streets.

## Settings

| Variable | Default | What it does |
|---|---|---|
| `HA_URL`, `HA_TOKEN` | | Home Assistant address and long-lived token |
| `RADARES_SOURCES` | `dgt,osm,murcia` | which sources to use |
| `RADARES_DGT_PROVINCES` | `30` | INE province codes for DGT radars (30 is Murcia) |
| `RADARES_OSM_BBOX` | Región de Murcia | `south,west,north,east` for OpenStreetMap cameras |
| `RADARES_FIXED_RADIUS` | `500` | metres around a fixed radar |
| `RADARES_STREET_RADIUS` | `300` | metres of each circle along an announced street |
| `RADARES_NOTIFY` | | notify services told to open the app after a change |
| `RADARES_INTERVAL` | `3600` | seconds between runs |
| `RADARES_CACHE` | `~/.cache/radares-anunciados` | where downloads are cached |

`radares feed` prints the merged list as GeoJSON, for anyone who wants the data without Home
Assistant. [How it works](how-it-works.md) covers the sources and the zone logic.
