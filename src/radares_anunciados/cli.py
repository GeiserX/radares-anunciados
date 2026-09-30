"""Command line: build the feed, sync it to Home Assistant, or do both on a loop.

Configuration comes from the environment so the same image runs anywhere:

  RADARES_SOURCES        dgt,osm,murcia
  RADARES_DGT_PROVINCES  INE province codes, e.g. 30 (Murcia)
  RADARES_OSM_BBOX       south,west,north,east (default: Región de Murcia)
  RADARES_FIXED_RADIUS   metres around a fixed radar (default 500)
  RADARES_STREET_RADIUS  metres of each circle along an announced street (default 300)
  HA_URL, HA_TOKEN       Home Assistant base URL and long-lived access token
  RADARES_NOTIFY         notify services told to open the app after a change,
                         e.g. notify.mobile_app_phone1,notify.mobile_app_phone2
  RADARES_INTERVAL       seconds between runs for `radares run` (default 3600)
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
import time
from datetime import date

from . import feed, ha, net
from .model import Radar
from .sources import dgt, murcia, osm

log = logging.getLogger("radares")


def _env_list(name: str, default: str = "") -> list[str]:
    return [x.strip() for x in os.environ.get(name, default).split(",") if x.strip()]


def collect(day: date) -> list[Radar]:
    sources = set(_env_list("RADARES_SOURCES", "dgt,osm,murcia"))
    fixed_r = int(os.environ.get("RADARES_FIXED_RADIUS", "500"))
    street_r = int(os.environ.get("RADARES_STREET_RADIUS", "300"))
    radars: list[Radar] = []
    # One source failing must not wipe the others' zones: a failed source
    # aborts the run, and Home Assistant keeps last run's zones.
    if "dgt" in sources:
        provinces = set(_env_list("RADARES_DGT_PROVINCES", "30"))
        radars += dgt.parse(net.get(dgt.URL), provinces, radius_m=fixed_r)
    if "osm" in sources:
        bbox = tuple(float(x) for x in _env_list("RADARES_OSM_BBOX")) or osm.MURCIA_REGION
        payload = net.get(osm.OVERPASS_URL, {"data": osm.query(bbox)})
        radars += osm.parse(payload, radius_m=fixed_r)
    if "murcia" in sources:
        radars += murcia.fetch(day, radius_m=street_r)
    return feed.merge(radars, day)


async def _sync(radars: list[Radar], dry_run: bool) -> ha.Plan:
    url, token = os.environ.get("HA_URL"), os.environ.get("HA_TOKEN")
    if not url or not token:
        raise SystemExit("HA_URL and HA_TOKEN must be set")
    async with ha.HomeAssistant(url, token) as client:
        todo = await client.sync(radars, dry_run=dry_run)
        targets = _env_list("RADARES_NOTIFY")
        if not dry_run and targets and (todo.create or todo.delete):
            await client.notify(
                targets,
                "Radares actualizados",
                f"{len(todo.create)} zonas nuevas, {len(todo.delete)} retiradas. "
                "Toca para cargarlas en el móvil.",
            )
        return todo


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="radares", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_feed = sub.add_parser("feed", help="print the merged radar list as GeoJSON")
    p_feed.add_argument("-o", "--output", help="write to this file instead of stdout")
    p_sync = sub.add_parser("sync", help="make Home Assistant zones equal to the radar list")
    p_sync.add_argument("--dry-run", action="store_true", help="show the plan, change nothing")
    sub.add_parser("run", help="sync every RADARES_INTERVAL seconds, forever")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.command == "feed":
        text = feed.to_geojson(collect(date.today()))
        if args.output:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text + "\n")
        return 0

    if args.command == "sync":
        radars = collect(date.today())
        todo = asyncio.run(_sync(radars, args.dry_run))
        for spec in todo.create:
            print(f"+ {spec.name} ({spec.latitude}, {spec.longitude}) r={spec.radius:.0f}")
        print(
            f"{len(radars)} radars: {todo.keep} kept, {len(todo.create)} created, "
            f"{len(todo.delete)} deleted" + (" (dry run)" if args.dry_run else "")
        )
        return 0

    interval = int(os.environ.get("RADARES_INTERVAL", "3600"))
    while True:
        try:
            radars = collect(date.today())
            asyncio.run(_sync(radars, dry_run=False))
        except Exception:  # keep the loop alive; the next run retries
            log.exception("run failed; Home Assistant keeps the previous zones")
        time.sleep(interval)
