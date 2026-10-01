"""Command line: build the feed, sync it to Home Assistant, or do both on a loop.

Configuration comes from the environment so the same image runs anywhere:

  RADARES_SOURCES        which sources to use (default: every registered one)
  RADARES_PROVINCES      INE province codes, e.g. 30 (Murcia, the default), or all;
                         RADARES_DGT_PROVINCES is the old name and still works
  RADARES_OSM_BBOX       south,west,north,east, or all (default: the provinces' boxes)
  RADARES_FIXED_RADIUS   metres around a fixed radar, or auto (default: by its limit)
  RADARES_STREET_RADIUS  metres of each circle along an announced street, or auto
  RADARES_MAX_ZONES      most radar zones in Home Assistant (default 1000)
  RADARES_DORMANT_WEEKS  weeks an announced street keeps its zones, silent, after
                         its period ends (default 26; 0 deletes them at once)
  HA_URL, HA_TOKEN       Home Assistant base URL and long-lived access token
  RADARES_NOTIFY         notify services told to open the app after a change,
                         e.g. notify.mobile_app_phone1,notify.mobile_app_phone2
  RADARES_INTERVAL       seconds between runs for `radares run` (default 3600)
  RADARES_CACHE          directory for cached downloads (default ~/.cache/radares-anunciados)
  RADARES_METRICS_PORT   port of /metrics and /healthz for `radares run` (default 9464;
                         empty or 0 turns them off)
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from datetime import date

from . import feed, ha, metrics, provinces, sources, speed, store
from .model import Radar, Stretch
from .sources import Context, Outcome
from .streets import Announced, WeeklyList

log = logging.getLogger("radares")

NUDGE_AFTER_S = 20  # longer than the iOS app's 15 s window between zone stores


def _env_list(name: str, default: str = "") -> list[str]:
    return [x.strip() for x in os.environ.get(name, default).split(",") if x.strip()]


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip()
    try:
        return int(raw) if raw else default
    except ValueError:
        raise ValueError(f"{name}={raw!r} is not a whole number") from None


def selected_provinces() -> frozenset[str] | None:
    raw = os.environ.get("RADARES_PROVINCES") or os.environ.get("RADARES_DGT_PROVINCES") or "30"
    return provinces.parse(raw)


def osm_boxes(codes: frozenset[str] | None) -> tuple[provinces.Box, ...]:
    """RADARES_OSM_BBOX as given, every box of Spain for "all", else the boxes of
    the selected provinces."""
    raw = os.environ.get("RADARES_OSM_BBOX", "").strip()
    if raw.lower() == "all":
        return tuple(provinces.boxes(None))
    if raw:
        box = tuple(float(x) for x in raw.split(","))
        if len(box) != 4:
            raise ValueError(f"RADARES_OSM_BBOX={raw!r} is not south,west,north,east")
        return (box,)
    return tuple(provinces.boxes(codes))


def context(day: date) -> Context:
    codes = selected_provinces()
    return Context(day=day, provinces=codes, boxes=osm_boxes(codes), radius=speed.Radius.from_env())


@dataclass
class Collected:
    radars: list[Radar]  # merged: in force today and dormant
    lists: list[WeeklyList]
    stretches: list[Stretch] = field(default_factory=list)
    outcomes: list[Outcome] = field(default_factory=list)

    def source_status(self) -> dict[str, tuple[bool, float | None]]:
        return {o.key: (o.up, o.fetched_at) for o in self.outcomes}


def collect(day: date, save_history: bool = True) -> Collected:
    """Every selected source, merged, with the dormant streets. Never fails for a
    source: a failed one gives its last good result (see ``sources.run``).

    Only a run that syncs Home Assistant for real saves the history of announced
    streets; ``radares feed`` and ``sync --dry-run`` read it and leave it alone."""
    ctx = context(day)
    keys = _env_list("RADARES_SOURCES") or None
    outcomes = sources.run_all(sources.selected(keys, ctx.provinces), ctx)
    radars = [r for o in outcomes for r in o.result.radars]
    stretches = [s for o in outcomes for s in o.result.stretches]
    lists = [w for o in outcomes for w in o.result.lists]
    if ctx.provinces is not None:  # a source that knows the province says so
        radars = [r for r in radars if r.province is None or r.province in ctx.provinces]
        stretches = [s for s in stretches if s.province is None or s.province in ctx.provinces]
    radars = speed.size(speed.fill_limits(radars), ctx.radius)
    weeks = _env_int("RADARES_DORMANT_WEEKS", 26)
    remembered, history = feed.remember(store.load_announced(), radars, day, weeks)
    if save_history:
        store.save_announced(history)
    return Collected(feed.merge(radars + remembered, day), lists, stretches, outcomes)


def message(todo: ha.Plan, lists: list[WeeklyList]) -> str:
    """The "Radares actualizados" text. It names every announced street left
    without a zone, so the driver knows that street gives no warning."""
    text = f"{len(todo.create)} zonas nuevas, {len(todo.delete)} retiradas."
    skipped = [s.label() for w in lists for s in w.skipped]
    if skipped:
        text += f" Sin aviso, no encontradas en el mapa: {', '.join(skipped)}."
    return text + " Toca para cargarlas en el móvil."


async def _sync(
    radars: list[Radar],
    lists: list[WeeklyList],
    dry_run: bool,
    told: set[tuple[str, Announced]] | None = None,
) -> ha.Plan:
    """Make the zones equal to ``radars`` and notify the phones of a change.

    ``told`` is the set of skipped streets of the previous run, kept by ``radares
    run``. A skipped street creates no zone, so a new set of them notifies on its
    own; the same set again does not. Without ``told`` only zone changes notify."""
    url, token = os.environ.get("HA_URL"), os.environ.get("HA_TOKEN")
    if not url or not token:
        raise SystemExit("HA_URL and HA_TOKEN must be set")
    max_zones = _env_int("RADARES_MAX_ZONES", ha.MAX_ZONES)
    if max_zones < 1:
        raise ValueError(f"RADARES_MAX_ZONES={max_zones} must be 1 or more")
    async with ha.HomeAssistant(url, token) as client:
        todo = await client.sync(radars, dry_run=dry_run, max_zones=max_zones)
        targets = _env_list("RADARES_NOTIFY")
        skipped = {(w.source, s) for w in lists for s in w.skipped}
        news = told is not None and skipped and skipped != told
        if not dry_run and targets and (todo.create or todo.delete or news):
            await client.notify(targets, "Radares actualizados", message(todo, lists))
        if told is not None and not dry_run:
            told.clear()
            told.update(skipped)
        if todo.changed and not dry_run:
            # An open iOS app stored only the first zone of that burst; one more
            # change after its 15 s window makes it store the whole set.
            await asyncio.sleep(NUDGE_AFTER_S)
            try:
                zone_id = await client.nudge()
                log.info("touched %s so an open iOS app stores every zone", zone_id)
            except Exception:  # the zones changed; the next change touches again
                log.exception("could not touch a zone after the sync; the zones are synced")
        return todo


def run_once(state: metrics.State, told: set[tuple[str, Announced]] | None = None) -> bool:
    """One collect + sync of ``radares run``, recorded in ``state``. Never raises:
    a failed run leaves Home Assistant with the previous zones and the next retries."""
    try:
        found = collect(date.today())
        state.collected(found.radars, found.lists, found.source_status())
        todo = asyncio.run(_sync(found.radars, found.lists, dry_run=False, told=told))
        state.synced(todo.keep, len(todo.create), len(todo.delete), len(todo.update), todo.left_out)
    except Exception:
        log.exception("run failed; Home Assistant keeps the previous zones")
        state.finished(ok=False)
        return False
    state.finished(ok=True)
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="radares", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p_feed = sub.add_parser("feed", help="print the merged radar list as GeoJSON")
    p_feed.add_argument("-o", "--output", help="write to this file instead of stdout")
    p_sync = sub.add_parser("sync", help="make Home Assistant zones equal to the radar list")
    p_sync.add_argument("--dry-run", action="store_true", help="show the plan, change nothing")
    sub.add_parser("run", help="sync every RADARES_INTERVAL seconds, forever")
    sub.add_parser("health", help="exit 0 if `radares run` synced recently (container check)")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    if args.command == "feed":
        found = collect(date.today(), save_history=False)
        text = feed.to_geojson(found.radars, found.stretches)
        if args.output:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text + "\n")
        return 0

    if args.command == "sync":
        found = collect(date.today(), save_history=not args.dry_run)
        todo = asyncio.run(_sync(found.radars, found.lists, args.dry_run))
        for zone_id in todo.delete:
            print(f"- {zone_id}")
        for zone_id, icon in todo.update:
            print(f"~ {zone_id} icon={icon}")
        for spec in todo.create:
            print(
                f"+ {spec.name} ({spec.latitude}, {spec.longitude}) r={spec.radius:.0f} {spec.icon}"
            )
        print(
            f"{len(found.radars)} radars: {todo.keep} kept, {len(todo.update)} updated, "
            f"{len(todo.create)} created, {len(todo.delete)} deleted, {todo.left_out} left out"
            + (" (dry run)" if args.dry_run else "")
        )
        return 0

    if args.command == "health":
        try:
            port = metrics.port_from_env()
        except ValueError as exc:
            print(f"health check failed: {exc}")
            return 1
        return metrics.check(port)

    interval = int(os.environ.get("RADARES_INTERVAL", "3600"))
    state = metrics.State(interval)
    # The sync is the product: a metrics server that can't start must not stop it.
    # `radares health` then fails, so the container shows unhealthy.
    try:
        port = metrics.port_from_env()
        if port is not None:
            metrics.serve(state, port)
            log.info("metrics on :%d/metrics, health on :%d/healthz", port, port)
    except (ValueError, OSError) as exc:
        log.error("metrics server not started, syncing without metrics: %s", exc)
    told: set[tuple[str, Announced]] = set()
    while True:
        run_once(state, told)
        time.sleep(interval)
