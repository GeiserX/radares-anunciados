import asyncio
import time
from datetime import date

import pytest

from radares_anunciados import cli, ha, metrics


class FakeHA:
    """Records what a sync does, in order."""

    calls: list[str]
    plan: ha.Plan

    def __init__(self, url, token):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        pass

    async def sync(self, radars, dry_run=False, max_zones=ha.MAX_ZONES):
        FakeHA.calls.append(f"sync max={max_zones} dry={dry_run}")
        return FakeHA.plan

    async def notify(self, targets, title, message):
        FakeHA.calls.append("notify")

    async def nudge(self):
        FakeHA.calls.append("nudge")
        if FakeHA.nudge_fails:
            raise ConnectionError("Home Assistant restarted")
        return "radar_x"


@pytest.fixture
def fake(monkeypatch):
    async def sleep(seconds):
        FakeHA.calls.append(f"sleep {seconds}")

    monkeypatch.setattr(ha, "HomeAssistant", FakeHA)
    monkeypatch.setattr(cli.asyncio, "sleep", sleep)
    monkeypatch.setenv("HA_URL", "http://ha.test")
    monkeypatch.setenv("HA_TOKEN", "t")
    monkeypatch.setenv("RADARES_NOTIFY", "notify.mobile_app_phone1")
    monkeypatch.delenv("RADARES_MAX_ZONES", raising=False)
    FakeHA.calls = []
    FakeHA.nudge_fails = False
    return FakeHA


@pytest.mark.parametrize(
    "plan",
    [
        ha.Plan(create=[ha.ZoneSpec("Radar x", 37.0, -1.0, 500.0)], delete=[], keep=0),
        ha.Plan(create=[], delete=["z"], keep=0),
        ha.Plan(create=[], delete=[], keep=1, update=[("z", ha.DORMANT_ICON)]),
    ],
)
def test_a_sync_that_changed_zones_touches_one_again_after_20_s(fake, plan):
    fake.plan = plan
    asyncio.run(cli._sync([], [], dry_run=False))
    assert fake.calls[-2:] == [f"sleep {cli.NUDGE_AFTER_S}", "nudge"]
    assert cli.NUDGE_AFTER_S > 15  # the iOS app drops changes within 15 s of a store


def test_no_change_or_a_dry_run_touches_nothing(fake):
    fake.plan = ha.Plan(create=[], delete=[], keep=3)
    asyncio.run(cli._sync([], [], dry_run=False))
    assert "nudge" not in fake.calls
    fake.plan = ha.Plan(create=[ha.ZoneSpec("Radar x", 37.0, -1.0, 500.0)], delete=[], keep=0)
    asyncio.run(cli._sync([], [], dry_run=True))
    assert "nudge" not in fake.calls and "notify" not in fake.calls


def test_the_cap_comes_from_the_environment(fake, monkeypatch):
    fake.plan = ha.Plan(create=[], delete=[], keep=0)
    asyncio.run(cli._sync([], [], dry_run=True))
    monkeypatch.setenv("RADARES_MAX_ZONES", "3000")
    asyncio.run(cli._sync([], [], dry_run=True))
    assert fake.calls == ["sync max=1000 dry=True", "sync max=3000 dry=True"]


def test_an_icon_only_change_does_not_ask_the_phones_to_open_the_app(fake):
    # The phone monitors regions, not icons: nothing for it to load.
    fake.plan = ha.Plan(create=[], delete=[], keep=1, update=[("z", ha.DORMANT_ICON)])
    asyncio.run(cli._sync([], [], dry_run=False))
    assert "notify" not in fake.calls


@pytest.mark.parametrize("cap", ["0", "-1"])
def test_a_cap_below_one_is_refused(fake, monkeypatch, cap):
    # Slicing by 0 or -1 would delete every zone or keep all but the last
    fake.plan = ha.Plan(create=[], delete=[], keep=0)
    monkeypatch.setenv("RADARES_MAX_ZONES", cap)
    with pytest.raises(ValueError, match="RADARES_MAX_ZONES"):
        asyncio.run(cli._sync([], [], dry_run=True))
    assert fake.calls == []


def test_a_failed_touch_does_not_fail_a_sync_that_changed_zones(fake):
    # The zones changed and the phones were told; only the extra touch was lost.
    fake.plan = ha.Plan(create=[ha.ZoneSpec("Radar x", 37.0, -1.0, 500.0)], delete=[], keep=0)
    fake.nudge_fails = True
    assert asyncio.run(cli._sync([], [], dry_run=False)) is fake.plan
    assert fake.calls[-3:] == ["notify", f"sleep {cli.NUDGE_AFTER_S}", "nudge"]


class Collecting(Exception):
    pass


@pytest.mark.parametrize(
    ("utc", "day"),
    [
        (1_785_537_000, date(2026, 8, 1)),  # 31 Jul 22:30 UTC, 00:30 in Madrid (summer)
        (1_798_759_800, date(2027, 1, 1)),  # 31 Dec 23:30 UTC, 00:30 in Madrid (winter)
    ],
)
def test_the_day_is_spains_whatever_the_time_zone_of_the_container(monkeypatch, tmp_path, utc, day):
    # A daily list (León, Donostia) is valid on a Spanish date. The container runs
    # on UTC, where the first hour or two of a Spanish day still read as yesterday.
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    try:
        monkeypatch.setattr(time, "time", lambda: float(utc))
        days = []

        def collect(day, save_history=True):
            days.append(day)
            if len(days) > 1:
                raise Collecting  # run_once logs it and carries on
            return cli.Collected([], [])

        monkeypatch.setattr(cli, "collect", collect)
        assert cli.main(["feed", "-o", str(tmp_path / "feed.json")]) == 0
        assert not cli.run_once(metrics.State(3600))
        assert days == [day, day]
    finally:
        monkeypatch.undo()
        time.tzset()
