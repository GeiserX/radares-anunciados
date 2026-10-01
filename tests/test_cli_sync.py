import asyncio

import pytest

from radares_anunciados import cli, ha


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
