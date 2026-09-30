from datetime import date
from pathlib import Path

from radares_anunciados.geo import distance_m
from radares_anunciados.sources.murcia import candidates, parse_article, parse_item, to_radars
from radares_anunciados.streets import Announced, locate, street_key

FIX = Path(__file__).parent / "fixtures"
LOS_DOLORES = (37.9769428, -1.105154)
SANTA_MARIA_DE_GRACIA = (37.9941988, -1.1393876)


def page(name: str) -> str:
    return (FIX / name).read_text(encoding="utf-8")


def all_weeks() -> list[Announced]:
    items: list[Announced] = []
    for f in sorted(FIX.glob("laopinion_2026-*.html")) + [FIX / "murciaactualidad_2026-08-17.html"]:
        for i in parse_article(f.read_text(encoding="utf-8")):
            if i not in items:
                items.append(i)
    return items


def test_laopinion_reads_the_primary_list_not_related_headlines():
    # 7 Jul has a plain ft-list of related headlines before the street list
    items = parse_article(page("laopinion_2026-07-07.html"))
    assert items[0] == Announced("Avenida La Azacaya", "Los Dolores")
    assert items[-1] == Announced("Carril Molino Batán", "La Raya")
    assert len(items) == 6


def test_laopinion_week_of_13_july_lists_camino_tinosa():
    items = parse_article(page("laopinion_2026-07-13.html"))
    assert Announced("Camino Tiñosa", "San José de la Vega") in items
    # "Avda. Juan Carlos I, Zig-Zag, Santa María de Gracia": middle part dropped
    assert Announced("Avenida Juan Carlos I", "Santa María de Gracia") in items


def test_laopinion_split_bold_and_en():
    # 28 Sep writes 'A<strong>venida Real Academia de Medicina</strong>, en El Ranero.'
    items = parse_article(page("laopinion_2026-09-28.html"))
    assert Announced("Avenida Real Academia de Medicina", "El Ranero") in items
    assert Announced("Costera Norte", "Cabezo de Torres") in items


def test_abbreviations_and_road_numbers():
    assert parse_item("Cno. Tiñosa, RM -F6, Los Dolores") == Announced(
        "Camino Tiñosa", "Los Dolores"
    )
    assert parse_item("C/ Mayor, El Raal") == Announced("Calle Mayor", "El Raal")
    assert parse_item("Avda. de Alicante, Murcia") == Announced("Avenida de Alicante", "Murcia")


def test_murciaactualidad_running_text():
    assert parse_article(page("murciaactualidad_2026-08-17.html")) == [
        Announced("Avenida de La Ñora", "La Albatalía"),
        Announced("Ronda Sur", "Santiago el Mayor"),
        Announced("Avenida Ciudad de Almería", "Murcia"),
    ]


def test_candidates_only_this_week():
    sitemap = page("laopinion_sitemapMonth.xml")
    this_week = candidates(sitemap, date(2026, 9, 30))
    assert [d for d, _ in this_week] == [date(2026, 9, 28)]
    assert candidates(sitemap, date(2026, 9, 23))[0][0] == date(2026, 9, 21)
    assert candidates(sitemap, date(2026, 10, 5)) == []  # next Monday: not out yet


def test_street_key_drops_bare_article():
    assert street_key("Avenida La Azacaya") == street_key("Avenida de la Azacaya")


def test_five_real_weeks_place_every_street_but_one():
    items = all_weeks()
    found = locate(items, (FIX / "overpass_weeks.json").read_bytes(), 300)
    missing = [i.street for i, c in found.items() if not c]
    # OSM has only "Camino del Batán" there; too different to guess
    assert missing == ["Carril Molino Batán"]


def test_common_name_picks_the_street_of_that_district():
    items = [
        Announced("Calle Mayor", "Los Dolores"),
        Announced("Avenida Juan Carlos I", "Santa María de Gracia"),
    ]
    found = locate(items, (FIX / "overpass_weeks.json").read_bytes(), 300)
    assert 0 < len(found[items[0]]) <= 6
    assert all(distance_m(c, LOS_DOLORES) < 2500 for c in found[items[0]])
    assert all(distance_m(c, SANTA_MARIA_DE_GRACIA) < 3000 for c in found[items[1]])


def test_district_written_differently_still_found():
    # press: "Santiago Zaraiche"; OSM: "Santiago y Zaraiche" (a boundary only)
    item = Announced("Avenida Juan de Borbón", "Santiago Zaraiche")
    assert locate([item], (FIX / "overpass_weeks.json").read_bytes(), 300)[item]


def test_unknown_district_places_nothing():
    item = Announced("Calle Mayor", "Nowhere That Exists")
    assert locate([item], (FIX / "overpass_weeks.json").read_bytes(), 300)[item] == []


def test_radars_valid_monday_to_sunday():
    items = [Announced("Camino Tiñosa", "San José de la Vega")]
    radars = to_radars(
        items, (FIX / "overpass_weeks.json").read_bytes(), date(2026, 7, 14), 300, "u"
    )
    assert radars
    assert {(r.valid_from, r.valid_to) for r in radars} == {(date(2026, 7, 13), date(2026, 7, 19))}
    assert all(r.name == "Radar anunciado Camino Tiñosa (San José de la Vega)" for r in radars)
    assert all(r.radius_m >= 100 for r in radars)


def test_ways_query_searches_around_each_district_only():
    from radares_anunciados.sources.murcia import BBOX
    from radares_anunciados.streets import NEAR_M, ways_query

    items = [Announced("Calle Mayor", "Los Dolores"), Announced("Calle Mayor", None)]
    q = ways_query(items, (FIX / "overpass_weeks.json").read_bytes(), BBOX)
    assert f"(around:{NEAR_M},37.976943,-1.105154)" in q  # the Los Dolores place node
    assert q.count("(around:") >= 1
    assert "(37.78,-1.4,38.1,-0.93)" in q  # no district: whole municipality


def _fake_net(monkeypatch, pages):
    """net.get that answers from ``pages`` (url -> bytes or OSError)."""
    from radares_anunciados.sources import murcia

    def get(url, data=None, headers=None, timeout=90, tries=3):
        answer = pages[url]
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(murcia.net, "get", get)
    return murcia


def test_find_article_skips_an_article_that_fails_to_download(monkeypatch):
    good = "https://www.laopiniondemurcia.es/murcia/2026/09/28/radares-semana-b.html"
    bad = "https://www.laopiniondemurcia.es/murcia/2026/09/29/radares-semana-a.html"
    sitemap = f"<urlset><url><loc>{bad}</loc></url><url><loc>{good}</loc></url></urlset>"
    murcia = _fake_net(
        monkeypatch,
        {
            murcia_sitemap(): sitemap.encode(),
            bad: OSError("timed out"),
            good: page("laopinion_2026-09-28.html").encode(),
        },
    )
    found = murcia.find_article(date(2026, 9, 30))
    assert found is not None and found[0] == good


def test_find_article_raises_when_a_download_failed_instead_of_an_empty_week(monkeypatch):
    import pytest

    murcia = _fake_net(
        monkeypatch,
        {murcia_sitemap(): OSError("406"), murcia_rss(): b"<rss></rss>"},
    )
    with pytest.raises(OSError):
        murcia.find_article(date(2026, 9, 30))


def test_find_article_returns_none_for_a_week_without_a_list(monkeypatch):
    murcia = _fake_net(
        monkeypatch, {murcia_sitemap(): b"<urlset></urlset>", murcia_rss(): b"<rss></rss>"}
    )
    assert murcia.find_article(date(2026, 9, 30)) is None


def murcia_sitemap():
    from radares_anunciados.sources.murcia import LAOPINION_SITEMAP

    return LAOPINION_SITEMAP


def murcia_rss():
    from radares_anunciados.sources.murcia import MURCIAACTUALIDAD_RSS

    return MURCIAACTUALIDAD_RSS
