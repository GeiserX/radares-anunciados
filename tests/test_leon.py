import json
import os
from datetime import date
from pathlib import Path

import pytest

from radares_anunciados import feed, net, sources
from radares_anunciados.geo import distance_m
from radares_anunciados.sources import Context, leon
from radares_anunciados.speed import Radius
from radares_anunciados.streets import Announced

FIX = Path(__file__).parent / "fixtures"
THURSDAY = date(2026, 10, 1)  # the week of 28 Sep - 4 Oct: September and October
NAVATEJERA = (42.627611, -5.565247)
RSS_URL = leon.RSS
SITEMAP_SEP = leon.ILEON_SITEMAP.format(year=2026, month=9)
ARTICLE_28 = (
    "https://ileon.eldiario.es/actualidad/radares-moviles-leon-semana-28-septiembre-4-octubre-"
    "calles-horarios-limites-velocidad_1_13543560.html"
)


def page(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


@pytest.fixture(autouse=True)
def clean_env(monkeypatch, tmp_path):
    for name in list(os.environ):
        if name.startswith("RADARES_"):
            monkeypatch.delenv(name)
    monkeypatch.setenv("RADARES_CACHE", str(tmp_path))


@pytest.fixture(scope="module")
def street_map() -> leon.StreetMap:
    return leon.StreetMap((FIX / "leon_overpass.json").read_bytes())


def october() -> list[leon.Slot]:
    (post,) = leon.council_posts(page("leon_rss_2026-10-01.xml"))
    return leon.parse_council(post.body, post.year, post.month)


# ---- reading the publications ---------------------------------------------


def test_the_rss_gives_the_october_post_and_nothing_else():
    (post,) = leon.council_posts(page("leon_rss_2026-10-01.xml"))
    assert (post.year, post.month, post.published) == (2026, 10, date(2026, 9, 28))
    assert post.url.endswith("ViewPost.aspx?ID=6891")


@pytest.mark.parametrize(
    "title, month, year",
    [
        ("Ubicación de radares mes de noviembre", 11, 2026),  # July 2026's wording
        ("Ubicación de radares mes de enero", 1, 2027),  # posted in September, no year
        ("El Ayuntamiento instala dos radares fijos", None, None),  # no month: not a schedule
        ("Actividades del mes de noviembre en los centros cívicos", None, None),  # no radares
    ],
)
def test_the_month_comes_from_the_title(title, month, year):
    rss = page("leon_rss_2026-10-01.xml").replace(
        "El Ayuntamiento de León informa de la ubicación de los radares móviles en el mes de "
        "octubre",
        title,
    )
    rss = rss.replace("octubre de 2026", "octubre")  # the body states no year either
    found = [(p.month, p.year) for p in leon.council_posts(rss)]
    assert found == ([(month, year)] if month else [])


def test_october_table_every_day_ten_streets_paired_with_their_limits():
    slots = october()
    assert len(slots) == 310  # 31 days, 5 streets a shift, two shifts
    assert {s.day for s in slots} == {date(2026, 10, d) for d in range(1, 32)}
    assert slots[0] == leon.Slot(date(2026, 10, 1), "Pº Salamanca", 30)
    day31 = [(s.text, s.maxspeed) for s in slots if s.day == date(2026, 10, 31)]
    assert ("LE-20", 70) in day31 and ("Avda. Portugal", 50) in day31
    assert ("Avda. Padre Isla (Prior. Peatonal)", 10) in day31


def test_two_streets_typed_in_one_paragraph_are_split():
    # 18 Oct afternoon: "San Ignacio de Loyola Avda. Magdalena" in one <p>, five limits
    day = [(s.text, s.maxspeed) for s in october() if s.day == date(2026, 10, 18)]
    assert ("San Ignacio de Loyola", 30) in day and ("Avda. Magdalena", 30) in day
    assert len(day) == 10


def test_september_table():
    slots = leon.parse_council(page("leon_council_2026-09_body.html"), 2026, 9)
    assert len(slots) == 300
    assert {s.day for s in slots} == {date(2026, 9, d) for d in range(1, 31)}


def test_a_pdf_month_has_no_table():
    # July 2026 was a PDF attachment: no slots, so iLeón covers those days
    assert leon.parse_council(page("leon_council_2026-07_body.html"), 2026, 7) == []


def test_ileon_week_of_28_september_crosses_into_october():
    published, slots = leon.parse_ileon(page("ileon_2026-09-28.html"))
    assert published == date(2026, 9, 28)
    assert len(slots) == 70
    assert slots[0] == leon.Slot(date(2026, 9, 28), "Avda. Madrid", 30)
    assert leon.Slot(date(2026, 10, 2), "LE-20 (Navatejera)", 70) in slots
    assert {s.day for s in slots} == set(leon.week_of(THURSDAY))


def test_ileon_reads_a_limit_cut_short():
    # 21 Sep writes "Ctra. Carbajal - 50 km/" and "Avda. San Froilán - 30 km/"
    _, slots = leon.parse_ileon(page("ileon_2026-09-21.html"))
    assert len(slots) == 70
    assert leon.Slot(date(2026, 9, 22), "Ctra. Carbajal", 50) in slots
    assert leon.Slot(date(2026, 9, 23), "Avda. San Froilán", 30) in slots


def test_ileon_candidates_newest_first():
    urls = leon.ileon_candidates(page("ileon_sitemap_2026_09.xml"))
    assert urls[0] == ARTICLE_28
    assert len(urls) == 4 and all("radares-moviles-leon" in u for u in urls)


# ---- the map --------------------------------------------------------------


def test_brackets_name_a_place_or_are_dropped(street_map):
    assert street_map.announced("LE-20 (Navatejera)") == Announced("LE-20", "Navatejera")
    assert street_map.announced("José Aguado (INCIBE)") == Announced("José Aguado", None)
    assert street_map.announced("Avda. Padre Isla (Prior. Peatonal)") == Announced(
        "Avenida Padre Isla", None
    )
    assert street_map.announced("Ingeniero Saez de Miera") == Announced(
        "Avenida Ingeniero Sáenz de Miera", None
    )


@pytest.mark.parametrize(
    "written, mapped",
    [
        ("Pº Salamanca", "Paseo de Salamanca"),
        ("Fdez. Ladreda.", "Avenida de Fernández Ladreda"),
        ("José M. Suárez G.", "Calle José María Suárez González"),
        ("Ing. S. Miera", "Avenida Ingeniero Sáenz de Miera"),
        ("Alcalde M. Castaño", "Avenida Alcalde Miguel Castaño"),
        ("Pº Condesa", "Paseo Condesa de Sagasta"),
        ("Avda. Facultad", "Avenida de la Facultad de Veterinaria"),
        ("Gutiérrez Mellado", "Calle General Gutiérrez Mellado"),
        ("San Ignacio de Loyoa", "Avenida San Ignacio de Loyola"),
    ],
)
def test_abbreviated_names_find_the_mapped_street(street_map, written, mapped):
    found = street_map.find(street_map.announced(written))
    assert found.ways and found.item.street == mapped


def test_a_name_also_used_by_a_neighbour_keeps_only_leons_street(street_map):
    # San Andrés del Rabanedo has an Avenida de Madrid too, west of León's border
    found = street_map.find(street_map.announced("Avda. Madrid"))
    assert found.ways
    assert all(g["lon"] > -5.62 for w in found.ways for g in w["geometry"])


def test_a_name_at_two_places_in_leon_is_skipped(street_map):
    found = street_map.find(Announced("Calle Mayor", None))
    assert not found.ways and found.reason == "name mapped at several places"


def test_a_road_mapped_in_pieces_is_one_road(street_map):
    # Carretera Vilecha (LE-5518) has an unnamed kilometre in the middle
    assert street_map.find(street_map.announced("Ctra. Vilecha")).ways
    assert street_map.find(street_map.announced("LE-20")).ways


def test_a_street_not_on_the_map_is_skipped(street_map):
    found = street_map.find(Announced("Calle Que No Existe", None))
    assert not found.ways and found.reason == "not on the map"


def test_a_bracketed_place_keeps_the_road_near_it(street_map):
    found = street_map.find(street_map.announced("LE-20 (Navatejera)"))
    centres = street_map.centres(found, 589)
    assert centres and all(distance_m(c, NAVATEJERA) < 3000 for c in centres)


def test_every_street_of_october_is_placed(street_map):
    """The placement rate over a full real month (and September's)."""
    for slots in (october(), leon.parse_council(page("leon_council_2026-09_body.html"), 2026, 9)):
        days = sorted({s.day for s in slots})
        schedule = leon.Schedule("u", date(2026, 9, 28), slots, leon.COUNCIL_ATTRIBUTION)
        radars, status = leon.to_radars([schedule], street_map, Radius().street_m, days)
        assert status.skipped == []
        assert len(status.streets) in (57, 53)  # October, September
        assert {r.valid_from for r in radars} == set(days)


# ---- radars ---------------------------------------------------------------


def test_each_street_is_valid_on_its_own_day_with_the_published_limit(street_map):
    schedule = leon.Schedule("u", date(2026, 9, 28), october(), leon.COUNCIL_ATTRIBUTION)
    radars, _ = leon.to_radars([schedule], street_map, Radius().street_m, leon.week_of(THURSDAY))
    assert all(r.valid_from == r.valid_to for r in radars)
    salamanca = [r for r in radars if r.name == "Radar anunciado Paseo de Salamanca"]
    assert {r.valid_from for r in salamanca} >= {date(2026, 10, 1), date(2026, 10, 3)}
    assert {r.maxspeed for r in salamanca} == {30}
    assert {r.radius_m for r in salamanca} == {Radius().street_m(30)}
    assert all(r.province == "24" and r.source == "leon" for r in radars)
    assert all(r.kind == "mobile_announced" and r.name.startswith("Radar") for r in radars)
    assert len({r.id for r in radars}) == len(radars)
    navatejera = [r for r in radars if r.name == "Radar anunciado LE-20 (Navatejera)"]
    assert navatejera and {r.maxspeed for r in navatejera} == {70}


def test_a_street_twice_on_one_day_takes_the_higher_limit(street_map):
    day = date(2026, 10, 31)
    slots = [
        leon.Slot(day, "Avda. Padre Isla (Prior. Peatonal)", 10),
        leon.Slot(day, "Avda. Padre Isla", 30),
    ]
    schedule = leon.Schedule("u", None, slots, leon.COUNCIL_ATTRIBUTION)
    radars, status = leon.to_radars([schedule], street_map, Radius().street_m, [day])
    assert {r.maxspeed for r in radars} == {30}
    assert len(status.streets) == 1


def test_a_skipped_street_is_reported_for_the_week_only(street_map):
    slots = [
        leon.Slot(date(2026, 10, 1), "Calle Que No Existe", 30),
        leon.Slot(date(2026, 10, 20), "Otra Que No Existe", 30),
        leon.Slot(date(2026, 10, 1), "Pº Salamanca", 30),
    ]
    schedule = leon.Schedule("u", date(2026, 9, 28), slots, leon.COUNCIL_ATTRIBUTION)
    radars, status = leon.to_radars(
        [schedule], street_map, Radius().street_m, leon.week_of(THURSDAY)
    )
    assert [s.street for s in status.skipped] == ["Calle Que No Existe"]
    assert [s.street for s in status.streets] == ["Calle Que No Existe", "Paseo de Salamanca"]
    assert radars and status.published == date(2026, 9, 28)


def test_the_feed_shows_a_street_on_its_day_and_dormant_after(street_map):
    schedule = leon.Schedule("u", date(2026, 9, 28), october(), leon.COUNCIL_ATTRIBUTION)
    radars, _ = leon.to_radars([schedule], street_map, Radius().street_m, leon.week_of(THURSDAY))
    on_1 = feed.merge(radars, date(2026, 10, 1))
    assert {r.valid_from for r in on_1} == {date(2026, 10, 1)}
    _, history = feed.remember([], radars, date(2026, 10, 1), weeks=4)
    remembered, _ = feed.remember(history, [], date(2026, 10, 2), weeks=4)
    assert remembered and not any(r.active for r in remembered)


# ---- fetch ----------------------------------------------------------------


def fake_net(monkeypatch, pages):
    calls = []

    def cached_get(url, data=None, headers=None, max_age_s=86_400):
        calls.append(url)
        body = pages.get(url)
        if isinstance(body, Exception):
            raise body
        if body is None:
            raise OSError(f"404 {url}")
        return body if isinstance(body, bytes) else body.encode()

    def get(url, data=None, headers=None, timeout=90, tries=3):
        return cached_get(url, data, headers)

    monkeypatch.setattr(net, "cached_get", cached_get)
    monkeypatch.setattr(net, "get", get)
    return calls


def pages(**overrides):
    base = {
        RSS_URL: page("leon_rss_2026-10-01.xml"),
        SITEMAP_SEP: page("ileon_sitemap_2026_09.xml"),
        ARTICLE_28: page("ileon_2026-09-28.html"),
        leon.OVERPASS: (FIX / "leon_overpass.json").read_bytes(),
    }
    return base | overrides


def ctx(day=THURSDAY) -> Context:
    return Context(day=day, provinces=frozenset({"24"}), boxes=(), radius=Radius())


def test_fetch_takes_october_from_the_council_and_september_from_ileon(monkeypatch):
    fake_net(monkeypatch, pages())
    result = leon.fetch(ctx())
    days = {r.valid_from: r.url for r in result.radars}
    assert days[date(2026, 9, 28)] == ARTICLE_28
    assert days[date(2026, 10, 1)].endswith("ID=6891")
    assert max(days) == date(2026, 10, 31)  # the whole month the post gives
    sep = {r.attribution for r in result.radars if r.valid_from.month == 9}
    assert sep == {leon.ILEON_ATTRIBUTION}
    (status,) = result.lists
    assert status.week == date(2026, 9, 28) and status.published == date(2026, 9, 28)
    assert status.streets and status.skipped == []


def test_the_post_is_kept_after_the_rss_forgets_it(monkeypatch):
    fake_net(monkeypatch, pages())
    first = leon.fetch(ctx())
    rss = page("leon_rss_2026-10-01.xml")
    forgotten = rss[: rss.index("<item>", rss.index("</item>"))] + "</channel></rss>"
    assert not leon.council_posts(forgotten)
    fake_net(monkeypatch, pages(**{RSS_URL: forgotten}))
    again = leon.fetch(ctx(date(2026, 10, 14)))  # no iLeón for that week in the fixtures
    assert {r.valid_from for r in again.radars} == {
        r.valid_from for r in first.radars if r.valid_from.month == 10
    }


def test_fetch_raises_when_downloads_fail_and_the_week_is_not_covered(monkeypatch):
    fake_net(monkeypatch, {})
    with pytest.raises(OSError):
        leon.fetch(ctx())


def test_a_failed_fallback_does_not_matter_when_today_on_is_covered(monkeypatch):
    # Thursday 1 Oct: the October post covers today to Sunday; 28-30 Sep are
    # past, so iLeón failing to answer must not take León down.
    fake_net(monkeypatch, pages(**{SITEMAP_SEP: OSError("timed out")}))
    result = leon.fetch(ctx())
    assert {r.valid_from for r in result.radars} >= {date(2026, 10, d) for d in range(1, 5)}
    assert all(r.valid_from.month == 10 for r in result.radars)


def test_a_failed_fallback_still_fails_when_a_day_ahead_is_uncovered(monkeypatch):
    # Monday 28 Sep: 28-30 Sep are still ahead and only iLeón has them.
    fake_net(monkeypatch, pages(**{SITEMAP_SEP: OSError("timed out")}))
    with pytest.raises(OSError):
        leon.fetch(ctx(date(2026, 9, 28)))


def test_a_bad_overpass_answer_is_not_kept(monkeypatch):
    # Overpass answers 200 with an error remark when busy. Caching that copy
    # would keep León down for the month the map is cached. Real file cache here.
    busy = b'{"elements":[],"remark":"runtime error: Query timed out in \\"query\\" at line 3"}'
    answers = pages()
    calls = []

    def get(url, data=None, headers=None, timeout=90, tries=3):
        calls.append(url)
        return answers[url] if isinstance(answers[url], bytes) else answers[url].encode()

    monkeypatch.setattr(net, "get", get)
    for bad in (busy, b"<html>502 Bad Gateway</html>"):
        answers[leon.OVERPASS] = bad
        with pytest.raises(OSError):
            leon.fetch(ctx())
        assert not list(net.cache_dir().glob("leon-overpass-*"))  # nothing kept
    answers[leon.OVERPASS] = (FIX / "leon_overpass.json").read_bytes()
    assert leon.fetch(ctx()).radars  # Overpass healthy again: the next run recovers
    assert calls.count(leon.OVERPASS) == 3
    assert leon.fetch(ctx()).radars  # and the good map is now cached
    assert calls.count(leon.OVERPASS) == 3
    (cached,) = net.cache_dir().glob("leon-overpass-*")
    cached.write_bytes(busy)  # a copy cached before this check existed is not trusted
    assert leon.fetch(ctx()).radars
    assert calls.count(leon.OVERPASS) == 4


def test_nothing_published_yet_is_an_empty_week(monkeypatch):
    rss = page("leon_rss_2026-10-01.xml")
    no_radars = rss[: rss.index("<item>", rss.index("</item>"))] + "</channel></rss>"
    sitemap = page("ileon_sitemap_2026_09.xml").replace("radares-moviles-leon", "otra-cosa")
    fake_net(monkeypatch, pages(**{RSS_URL: no_radars, SITEMAP_SEP: sitemap}))
    result = leon.fetch(ctx())
    assert result.radars == []
    assert [(w.source, w.week, w.published) for w in result.lists] == [
        ("leon", date(2026, 9, 28), None)
    ]


def test_registered_for_leon_only():
    source = sources.REGISTRY["leon"]
    assert source.provinces == {"24"} and source.spanish_ip
    assert "CC BY-NC 4.0" in source.licence and "no reuse licence" in source.licence
    assert [s.key for s in sources.selected(None, frozenset({"24"}))] == ["dgt", "osm", "leon"]


def test_overpass_error_answer_is_a_failure():
    # Overpass answers 200 with a partial map and a remark when it runs out of time
    partial = json.loads((FIX / "leon_overpass.json").read_bytes())
    partial["remark"] = "runtime error: Query run out of memory using about 2048 MB of RAM."
    with pytest.raises(OSError):
        leon.StreetMap(json.dumps(partial).encode())
    with pytest.raises(OSError):  # no border, no way to tell León's streets apart
        leon.StreetMap(replace_border(b"relation"))


def replace_border(kind: bytes) -> bytes:
    raw = (FIX / "leon_overpass.json").read_bytes()
    return raw.replace(b'"type":"' + kind + b'"', b'"type":"area"')


def test_week_of():
    assert leon.week_of(THURSDAY)[0] == date(2026, 9, 28)
    assert leon.week_of(THURSDAY)[-1] == date(2026, 10, 4)
