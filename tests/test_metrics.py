import asyncio
import re
import socket
import threading
import time
import urllib.error
import urllib.request
from datetime import date
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from radares_anunciados import __version__, cli, ha, metrics
from radares_anunciados.model import Radar
from radares_anunciados.streets import Announced, WeeklyList

DOCS = Path(__file__).parent.parent / "docs"
T0 = 1_790_000_000.0


def radar(source: str, n: int) -> Radar:
    return Radar(f"{source}-{n}", source, "fixed", "Radar", lat=37, lon=-1, radius_m=300)


def weekly(found: bool = True) -> WeeklyList:
    batan = Announced("Carril Molino Batán", "La Raya")
    return WeeklyList(
        "murcia",
        date(2026, 9, 28),
        published=date(2026, 9, 28) if found else None,
        streets=[Announced("Costera Norte", "Cabezo de Torres"), batan] if found else [],
        skipped=[batan] if found else [],
    )


def samples(text: str) -> dict[str, float]:
    """'name{labels}' -> value, for every sample line."""
    out = {}
    for line in text.splitlines():
        if line and not line.startswith("#"):
            key, value = line.rsplit(" ", 1)
            out[key] = float(value)
    return out


def test_before_the_first_run_only_static_metrics():
    s = samples(metrics.State(3600, now=T0).render())
    assert s[f'radares_build_info{{version="{__version__}"}}'] == 1
    assert s["radares_interval_seconds"] == 3600
    assert s["radares_consecutive_failed_runs"] == 0
    assert "radares_last_success_timestamp_seconds" not in s
    assert not any(k.startswith("radares_weekly_list") for k in s)


def test_a_successful_run_reports_sources_zones_and_the_weekly_list():
    state = metrics.State(3600, now=T0)
    state.collected([radar("dgt", 1), radar("dgt", 2), radar("murcia", 1)], [weekly()])
    state.synced(keep=80, created=6, deleted=5)
    state.finished(ok=True, now=T0 + 60)
    s = samples(state.render())
    assert s['radares_radars{source="dgt"}'] == 2
    assert s['radares_radars{source="murcia"}'] == 1
    assert s['radares_sync_zones{action="kept"}'] == 80
    assert s['radares_sync_zones{action="created"}'] == 6
    assert s['radares_sync_zones{action="deleted"}'] == 5
    assert s["radares_last_run_timestamp_seconds"] == T0 + 60
    assert s["radares_last_success_timestamp_seconds"] == T0 + 60
    assert s['radares_weekly_list_found{source="murcia"}'] == 1
    # 2026-09-28T00:00:00Z
    assert s['radares_weekly_list_published_timestamp_seconds{source="murcia"}'] == 1790553600
    assert s['radares_weekly_list_streets{source="murcia"}'] == 2
    assert s['radares_weekly_list_streets_skipped{source="murcia"}'] == 1
    key = 'radares_street_skipped{source="murcia",street="Carril Molino Batán",place="La Raya"}'
    assert s[key] == 1


def test_a_week_without_a_list_reads_zero_not_absent():
    state = metrics.State(3600, now=T0)
    state.collected([radar("dgt", 1)], [weekly(found=False)])
    s = samples(state.render())
    assert s['radares_weekly_list_found{source="murcia"}'] == 0
    assert s['radares_radars{source="murcia"}'] == 0
    assert 'radares_weekly_list_published_timestamp_seconds{source="murcia"}' not in s
    assert not any(k.startswith("radares_street_skipped{") for k in s)


def test_failures_count_up_and_a_success_resets_them():
    state = metrics.State(3600, now=T0)
    for n in range(3):
        state.finished(ok=False, now=T0 + n)
    s = samples(state.render())
    assert s["radares_consecutive_failed_runs"] == 3
    assert s["radares_last_run_timestamp_seconds"] == T0 + 2
    assert "radares_last_success_timestamp_seconds" not in s
    state.finished(ok=True, now=T0 + 10)
    assert samples(state.render())["radares_consecutive_failed_runs"] == 0


def test_label_values_are_escaped():
    state = metrics.State(3600, now=T0)
    odd = WeeklyList("murcia", date(2026, 9, 28), skipped=[Announced('Calle "X" \\ Y', None)])
    state.collected([], [odd])
    assert 'street="Calle \\"X\\" \\\\ Y",place=""} 1' in state.render()


def test_health_fails_after_three_intervals_without_success_and_recovers():
    state = metrics.State(100, now=T0)
    assert state.health(now=T0 + 300)[0]  # no run yet, still inside the grace
    ok, text = state.health(now=T0 + 301)
    assert not ok and text.startswith("stale: no success yet")
    state.finished(ok=True, now=T0 + 400)
    assert state.health(now=T0 + 700)[0]
    state.finished(ok=False, now=T0 + 500)
    assert not state.health(now=T0 + 701)[0]


@pytest.fixture
def server():
    state = metrics.State(100)
    srv = metrics.serve(state, 0, host="127.0.0.1")
    yield state, srv.server_address[1]
    srv.shutdown()
    srv.server_close()


def get(port: int, path: str) -> tuple[int, str, str]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as r:
            return r.status, r.headers["Content-Type"], r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.headers["Content-Type"], e.read().decode()


def test_http_serves_metrics_and_health(server):
    state, port = server
    code, ctype, body = get(port, "/metrics")
    assert code == 200 and ctype.startswith("text/plain; version=0.0.4")
    assert "radares_consecutive_failed_runs 0" in body
    assert get(port, "/healthz")[0] == 200
    assert get(port, "/nope")[0] == 404
    state.started -= 301  # no success for three intervals
    code, _, body = get(port, "/healthz")
    assert code == 503 and body.startswith("stale:")


def test_health_command_exit_codes(server, capsys):
    state, port = server
    assert metrics.check(port) == 0
    state.started -= 301
    assert metrics.check(port) == 1
    assert "stale" in capsys.readouterr().out
    assert metrics.check(None) == 0  # metrics off: nothing to check


def test_health_command_fails_when_nothing_listens():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        free = s.getsockname()[1]  # closed again before the check
    assert metrics.check(free, timeout=1) == 1


@pytest.mark.parametrize(
    ("value", "port"), [(None, metrics.DEFAULT_PORT), ("", None), ("0", None), ("9100", 9100)]
)
def test_port_from_env(monkeypatch, value, port):
    if value is None:
        monkeypatch.delenv("RADARES_METRICS_PORT", raising=False)
    else:
        monkeypatch.setenv("RADARES_METRICS_PORT", value)
    assert metrics.port_from_env() == port


def test_run_once_records_success_and_failure(monkeypatch):
    plan = ha.Plan(create=[], delete=["z1"], keep=4)

    async def sync(radars, lists, dry_run, told=None):
        return plan

    monkeypatch.setattr(cli, "collect", lambda day: cli.Collected([radar("dgt", 1)], [weekly()]))
    monkeypatch.setattr(cli, "_sync", sync)
    state = metrics.State(3600)
    assert cli.run_once(state)
    s = samples(state.render())
    assert s['radares_sync_zones{action="deleted"}'] == 1
    assert s['radares_weekly_list_streets_skipped{source="murcia"}'] == 1

    async def dead(radars, lists, dry_run, told=None):
        raise OSError("connection refused")

    monkeypatch.setattr(cli, "_sync", dead)
    assert not cli.run_once(state)
    assert not cli.run_once(state)
    s = samples(state.render())
    assert s["radares_consecutive_failed_runs"] == 2
    # the sources still answered, so the list status stays current
    assert s['radares_weekly_list_found{source="murcia"}'] == 1


def test_notification_names_the_streets_without_a_zone():
    plan = ha.Plan(create=[], delete=["a", "b"], keep=0)
    text = cli.message(plan, [weekly()])
    assert text == (
        "0 zonas nuevas, 2 retiradas. Sin aviso, no encontradas en el mapa: "
        "Carril Molino Batán (La Raya). Toca para cargarlas en el móvil."
    )
    assert "Sin aviso" not in cli.message(plan, [weekly(found=False)])


def test_a_later_run_replaces_the_weekly_list_state():
    a, b = Announced("Calle A", "Algezares"), Announced("Calle B", None)
    state = metrics.State(3600, now=T0)
    week = date(2026, 9, 28)
    state.collected([], [WeeklyList("murcia", week, week, streets=[a, b], skipped=[a, b])])
    assert samples(state.render())['radares_weekly_list_streets_skipped{source="murcia"}'] == 2

    state.collected([], [WeeklyList("murcia", week, week, streets=[a, b], skipped=[b])])
    s = samples(state.render())
    assert s['radares_weekly_list_streets_skipped{source="murcia"}'] == 1
    assert [k for k in s if k.startswith("radares_street_skipped{")] == [
        'radares_street_skipped{source="murcia",street="Calle B",place=""}'
    ]

    state.collected([], [weekly(found=False)])
    s = samples(state.render())
    assert s['radares_weekly_list_found{source="murcia"}'] == 0
    assert s['radares_weekly_list_streets{source="murcia"}'] == 0
    assert 'radares_weekly_list_published_timestamp_seconds{source="murcia"}' not in s
    assert not any(k.startswith("radares_street_skipped{") for k in s)


def test_list_missing_seconds_count_from_the_spanish_monday(monkeypatch):
    # The week rolls over on Spain's date (model.today_in_spain), so Monday starts at
    # 00:00 Madrid time (22:00 UTC on Sunday), whatever the container's TZ says.
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    try:
        state = metrics.State(3600, now=T0)
        state.collected([], [weekly(found=False)])
        tuesday = 1_790_632_810  # 2026-09-29 00:00:10 in Madrid
        key = 'radares_weekly_list_missing_seconds{source="murcia"}'
        assert samples(state.render(now=tuesday))[key] == 86_410
        state.collected([], [weekly()])
        assert samples(state.render(now=tuesday))[key] == 0
    finally:
        monkeypatch.undo()
        time.tzset()


class Stop(Exception):
    pass


@pytest.mark.parametrize("problem", ["port taken", "not a number"])
def test_run_keeps_syncing_when_the_metrics_server_cannot_start(monkeypatch, caplog, problem):
    runs = []

    def run_once(state, told=None):
        runs.append(state)
        raise Stop  # one run is enough: the loop got there

    monkeypatch.setattr(cli, "run_once", run_once)
    with socket.socket() as busy:
        busy.bind(("", 0))
        busy.listen()
        port = str(busy.getsockname()[1]) if problem == "port taken" else "nine"
        monkeypatch.setenv("RADARES_METRICS_PORT", port)
        with pytest.raises(Stop):
            cli.main(["run"])
    assert runs
    assert any(r.levelname == "ERROR" and "without metrics" in r.message for r in caplog.records)


def test_health_fails_when_the_metrics_port_is_not_a_number(monkeypatch, capsys):
    monkeypatch.setenv("RADARES_METRICS_PORT", "nine")
    assert cli.main(["health"]) == 1
    assert "RADARES_METRICS_PORT" in capsys.readouterr().out


def test_health_fails_when_another_server_holds_the_port():
    class Other(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"hello\n")

        def log_message(self, format, *args):
            pass

    srv = HTTPServer(("127.0.0.1", 0), Other)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        assert metrics.check(srv.server_address[1]) == 1
    finally:
        srv.shutdown()
        srv.server_close()


def test_health_fails_when_something_not_http_holds_the_port(capsys):
    with socket.socket() as other:
        other.bind(("127.0.0.1", 0))
        other.listen()

        def banner():
            conn, _ = other.accept()
            with conn:
                conn.sendall(b"SSH-2.0-OpenSSH\r\n")

        threading.Thread(target=banner, daemon=True).start()
        assert metrics.check(other.getsockname()[1], timeout=2) == 1
    assert capsys.readouterr().out.startswith("health check failed:")


def test_a_changed_set_of_skipped_streets_notifies_once(monkeypatch):
    sent = []

    class FakeHA:
        def __init__(self, url, token):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            pass

        async def sync(self, radars, dry_run=False, max_zones=ha.MAX_ZONES):
            return ha.Plan(create=[], delete=[], keep=3)  # no zone changes

        async def notify(self, targets, title, message):
            sent.append(message)

    monkeypatch.setattr(ha, "HomeAssistant", FakeHA)
    monkeypatch.setenv("HA_URL", "http://ha.test")
    monkeypatch.setenv("HA_TOKEN", "t")
    monkeypatch.setenv("RADARES_NOTIFY", "notify.mobile_app_phone1")
    told: set = set()

    def run(lists):
        asyncio.run(cli._sync([], lists, False, told))
        return len(sent)

    assert run([weekly()]) == 1  # Carril Molino Batán is new: told even with no zone change
    assert "Carril Molino Batán (La Raya)" in sent[0]
    assert run([weekly()]) == 1  # same set the next hour: quiet
    assert run([weekly(found=False)]) == 1  # nothing skipped: nothing to warn about
    assert run([weekly()]) == 2  # skipped again: told again
    two = weekly()
    two.skipped.append(Announced("Calle B", None))
    assert run([two]) == 3  # the set grew
    assert run([weekly()]) == 4  # and shrank
    # A one-shot `radares sync` keeps no memory, so only zone changes notify.
    asyncio.run(cli._sync([], [weekly()], False))
    assert len(sent) == 4


def test_every_metric_in_the_alerting_doc_exists():
    state = metrics.State(3600, now=T0)
    state.collected([radar("dgt", 1)], [weekly()], {"dgt": (True, T0)})
    state.synced(1, 0, 0)
    state.finished(ok=True, now=T0)
    exported = set(re.findall(r"^# TYPE (\w+) ", state.render(), re.M))
    used = set(re.findall(r"\bradares_[a-z_]+\b", (DOCS / "alerting.md").read_text("utf-8")))
    assert used, "the doc names no metric"
    assert used <= exported, used - exported
