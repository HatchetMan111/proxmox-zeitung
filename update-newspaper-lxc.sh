#!/usr/bin/env bash
# ============================================================
#  Zeitungs-LXC Update
#  Spielt die aktuelle App-Version in einen bereits bestehenden
#  Zeitungs-Container ein (Feeds/Ausgaben bleiben erhalten).
#  Ausfuehren auf der Proxmox-Host-Shell:
#    bash update-newspaper-lxc.sh
# ============================================================
set -euo pipefail

if ! command -v pct >/dev/null 2>&1; then
  echo "Dieses Skript muss auf einem Proxmox VE Host ausgefuehrt werden (Befehl 'pct' nicht gefunden)." >&2
  exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
  echo "Bitte als root ausfuehren." >&2
  exit 1
fi

read -rp "Container-ID der bestehenden Zeitung: " CTID
if [ -z "$CTID" ]; then
  echo "Container-ID erforderlich." >&2
  exit 1
fi
if ! pct status "$CTID" >/dev/null 2>&1; then
  echo "Container $CTID wurde nicht gefunden." >&2
  exit 1
fi

STAGE=$(mktemp -d)
mkdir -p "$STAGE/app/templates" "$STAGE/app/static" "$STAGE/systemd"

cat > "$STAGE/app/main.py" <<'ZEITUNG_FILE_EOF'
import json
import re
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import catalog
import db
import generator
import local_news

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = BASE_DIR.parent / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Zeitung")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

db.init_db()


def has_edition() -> bool:
    return (OUTPUT_DIR / "latest").exists()


def get_category_order():
    raw = db.get_setting("category_order")
    if not raw:
        return []
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []


def ordered_categories():
    """Alle aktuell genutzten Rubriken, sortiert nach gespeicherter Reihenfolge
    (unbekannte/neue Rubriken werden ans Ende angehaengt)."""
    used = db.distinct_categories()
    order = get_category_order()
    known = [c for c in order if c in used]
    unknown = sorted(c for c in used if c not in order)
    return known + unknown


def get_feed_stats():
    raw = db.get_setting("feed_stats")
    if not raw:
        return {}
    try:
        stats_list = json.loads(raw)
        return {s["url"]: s for s in stats_list}
    except (json.JSONDecodeError, TypeError, KeyError):
        return {}


RETENTION_DEFAULT = 30


def get_retention_days():
    raw = db.get_setting("retention_days")
    try:
        return max(1, int(raw)) if raw else RETENTION_DEFAULT
    except (TypeError, ValueError):
        return RETENTION_DEFAULT


def get_local_unlimited():
    return db.get_setting("local_unlimited") == "1"


def list_editions():
    if not OUTPUT_DIR.exists():
        return []
    dates = [
        p.name for p in OUTPUT_DIR.iterdir()
        if p.is_dir() and p.name != "latest" and (p / "index.html").exists()
    ]
    return sorted(dates, reverse=True)


@app.get("/", response_class=HTMLResponse)
def admin(request: Request):
    feeds = db.list_feeds()
    last_status = db.get_setting("last_status")
    return templates.TemplateResponse(
        request,
        "admin.html",
        {
            "feeds": feeds,
            "last_status": last_status,
            "has_edition": has_edition(),
            "categories": ordered_categories(),
            "catalog": catalog.CURATED_FEEDS,
            "edition_count": len(list_editions()),
            "feed_stats": get_feed_stats(),
            "retention_days": get_retention_days(),
            "local_unlimited": get_local_unlimited(),
        },
    )


@app.post("/feeds/add")
def feeds_add(
    url: str = Form(...),
    name: str = Form(""),
    category: str = Form("Allgemein"),
    priority: int = Form(1),
):
    db.add_feed(url.strip(), name.strip(), category.strip() or "Allgemein", priority)
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/bulk")
def feeds_bulk(feeds_text: str = Form(...)):
    added = 0
    for line in feeds_text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split("|")]
        url = parts[0]
        if not url:
            continue
        name = parts[1] if len(parts) > 1 else ""
        category = parts[2] if len(parts) > 2 else "Allgemein"
        try:
            priority = int(parts[3]) if len(parts) > 3 and parts[3] else 1
        except ValueError:
            priority = 1
        db.add_feed(url, name, category or "Allgemein", priority)
        added += 1
    db.set_setting("last_status", f"{added} Feed(s) importiert.")
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/catalog-add")
async def feeds_catalog_add(request: Request):
    form = await request.form()
    urls = form.getlist("urls")
    lookup = {url: (cat, name) for cat, items in catalog.CURATED_FEEDS.items() for name, url in items}
    added = 0
    for url in urls:
        cat, name = lookup.get(url, ("Allgemein", url))
        db.add_feed(url, name, cat, 1)
        added += 1
    db.set_setting("last_status", f"{added} Feed(s) aus dem Katalog hinzugefügt.")
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/local")
def feeds_local(plz: str = Form(...)):
    plz = plz.strip()
    if not local_news.PLZ_RE.match(plz):
        db.set_setting("last_status", "Bitte eine gültige 5-stellige PLZ eingeben.")
        return RedirectResponse("/", status_code=303)

    place = local_news.resolve_plz_de(plz)
    if not place:
        db.set_setting(
            "last_status",
            f"PLZ {plz} konnte nicht aufgelöst werden (Dienst nicht erreichbar oder PLZ unbekannt).",
        )
        return RedirectResponse("/", status_code=303)

    url = local_news.local_news_feed_url(place)
    if db.feed_exists(url):
        db.set_setting("last_status", f"Für {place} (PLZ {plz}) ist bereits eine lokale Rubrik eingerichtet.")
        return RedirectResponse("/", status_code=303)

    db.add_feed(url, f"Lokal: {place} ({plz})", "Lokales", priority=2)
    db.set_setting("last_status", f"Lokale Rubrik für {place} (PLZ {plz}) eingerichtet.")
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/local/repair")
def feeds_local_repair():
    """Aktualisiert bereits gespeicherte Lokal-Feed-URLs auf das aktuelle
    Abfrageformat (z.B. wenn sich local_news_feed_url() seit dem Einrichten
    des Feeds geaendert hat - ein App-Update allein aendert nichts an bereits
    in der Datenbank gespeicherten URLs)."""
    repaired = 0
    for f in db.feeds_by_category("Lokales"):
        if "news.google.com" not in f["url"]:
            continue
        m = re.search(r"\((\d{5})\)", f["name"] or "")
        if not m:
            continue
        place = local_news.resolve_plz_de(m.group(1))
        if not place:
            continue
        new_url = local_news.local_news_feed_url(place)
        if new_url != f["url"] and db.update_feed_url(f["id"], new_url):
            repaired += 1
    db.set_setting(
        "last_status",
        f"{repaired} lokale Feed-URL(s) auf das aktuelle Format aktualisiert."
        if repaired
        else "Alle lokalen Feed-URLs waren bereits aktuell.",
    )
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/{feed_id}/toggle")
def feeds_toggle(feed_id: int):
    db.toggle_feed(feed_id)
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/{feed_id}/delete")
def feeds_delete(feed_id: int):
    db.delete_feed(feed_id)
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/{feed_id}/priority")
def feeds_priority(feed_id: int, priority: int = Form(...)):
    db.set_priority(feed_id, max(1, min(3, priority)))
    return RedirectResponse("/", status_code=303)


@app.post("/settings/category-order")
def save_category_order(order: str = Form("")):
    cats = [c.strip() for c in order.split(",") if c.strip()]
    db.set_setting("category_order", json.dumps(cats))
    db.set_setting("last_status", "Rubrik-Reihenfolge gespeichert.")
    return RedirectResponse("/", status_code=303)


@app.post("/settings/retention")
def save_retention(days: int = Form(...)):
    days = max(1, min(365, days))
    db.set_setting("retention_days", str(days))
    db.set_setting("last_status", f"Ausgaben werden künftig {days} Tage aufbewahrt.")
    return RedirectResponse("/", status_code=303)


@app.post("/settings/local-unlimited")
def save_local_unlimited(enabled: str = Form("")):
    db.set_setting("local_unlimited", "1" if enabled else "0")
    db.set_setting(
        "last_status",
        "Zeigt künftig alle lokalen Schlagzeilen." if enabled else "Lokale Rubrik wieder wie andere Rubriken begrenzt.",
    )
    return RedirectResponse("/", status_code=303)


@app.post("/generate")
def generate_now():
    feeds = [dict(f) for f in db.enabled_feeds()]
    if not feeds:
        db.set_setting("last_status", "Keine aktiven Feeds - bitte zuerst einen Feed hinzufügen und anhaken.")
        return RedirectResponse("/", status_code=303)

    result = generator.build_edition(
        feeds, category_order=get_category_order(), local_unlimited=get_local_unlimited()
    )
    db.set_setting("feed_stats", json.dumps(result.get("feed_stats", [])))
    generator.cleanup_old_editions(get_retention_days())

    if result["article_count"] > 0:
        db.set_setting("last_run", result["date"])
        db.set_setting(
            "last_status",
            f"Ausgabe vom {result['date']} mit {result['article_count']} Artikel(n) "
            f"in {result['section_count']} Rubriken erstellt.",
        )
    else:
        db.set_setting(
            "last_status",
            "Es konnte kein Artikel aus den aktiven Feeds geladen werden. "
            "Details je Feed siehst du unten in der Feed-Tabelle.",
        )
    return RedirectResponse("/", status_code=303)


@app.get("/lesen")
def lesen():
    """Kurze, gut merkbare Lese-URL fürs Tablet - unabhängig von der Verwaltungsseite."""
    if not has_edition():
        return RedirectResponse("/", status_code=303)
    return RedirectResponse("/zeitung/latest/", status_code=307)


@app.get("/lesen.pdf")
def lesen_pdf():
    if not has_edition():
        return RedirectResponse("/", status_code=303)
    return RedirectResponse("/zeitung/latest/zeitung.pdf", status_code=307)


@app.get("/archiv", response_class=HTMLResponse)
def archiv(request: Request):
    dates = list_editions()
    return templates.TemplateResponse(request, "archiv.html", {"dates": dates})


@app.get("/read/{edition_date}")
def get_read(edition_date: str):
    return db.get_read_slugs(edition_date)


@app.post("/read/{edition_date}/{slug}")
def post_read(edition_date: str, slug: str):
    db.mark_read(edition_date, slug)
    return {"ok": True}


# Erst NACH den eigenen Routen mounten, damit /lesen und /archiv nicht vom
# StaticFiles-Mount verschluckt werden.
app.mount("/zeitung", StaticFiles(directory=str(OUTPUT_DIR), html=True), name="zeitung")
ZEITUNG_FILE_EOF
cat > "$STAGE/app/db.py" <<'ZEITUNG_FILE_EOF'
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "data" / "zeitung.db"


def get_conn():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def _column_exists(conn, table, column):
    cols = [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
    return column in cols


def init_db():
    conn = get_conn()
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS feeds (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT UNIQUE NOT NULL,
            name TEXT,
            category TEXT DEFAULT 'Allgemein',
            enabled INTEGER DEFAULT 1,
            added_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS read_articles (
            edition_date TEXT NOT NULL,
            slug TEXT NOT NULL,
            read_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (edition_date, slug)
        )
        """
    )
    # Migration fuer bestehende Installationen ohne die priority-Spalte.
    if not _column_exists(conn, "feeds", "priority"):
        conn.execute("ALTER TABLE feeds ADD COLUMN priority INTEGER DEFAULT 1")
    conn.commit()
    conn.close()


def list_feeds():
    conn = get_conn()
    rows = conn.execute("SELECT * FROM feeds ORDER BY category, name").fetchall()
    conn.close()
    return rows


def feed_exists(url):
    conn = get_conn()
    row = conn.execute("SELECT 1 FROM feeds WHERE url = ?", (url,)).fetchone()
    conn.close()
    return row is not None


def add_feed(url, name, category, priority=1):
    conn = get_conn()
    conn.execute(
        "INSERT OR IGNORE INTO feeds (url, name, category, priority) VALUES (?, ?, ?, ?)",
        (url, name or None, category or "Allgemein", priority),
    )
    conn.commit()
    conn.close()


def feeds_by_category(category):
    conn = get_conn()
    rows = conn.execute("SELECT * FROM feeds WHERE category = ?", (category,)).fetchall()
    conn.close()
    return rows


def update_feed_url(feed_id, new_url):
    """Aendert die URL eines bestehenden Feeds (z.B. um alte gespeicherte
    Google-News-Lokal-URLs auf ein neues Abfrageformat zu migrieren)."""
    conn = get_conn()
    try:
        conn.execute("UPDATE feeds SET url = ? WHERE id = ?", (new_url, feed_id))
        conn.commit()
        return True
    except sqlite3.IntegrityError:
        # neue URL kollidiert mit einem bereits vorhandenen Feed (UNIQUE) -
        # dann lieber den Duplikat-Eintrag entfernen als einen Fehler werfen.
        conn.execute("DELETE FROM feeds WHERE id = ?", (feed_id,))
        conn.commit()
        return False
    finally:
        conn.close()


def toggle_feed(feed_id):
    conn = get_conn()
    conn.execute("UPDATE feeds SET enabled = 1 - enabled WHERE id = ?", (feed_id,))
    conn.commit()
    conn.close()


def delete_feed(feed_id):
    conn = get_conn()
    conn.execute("DELETE FROM feeds WHERE id = ?", (feed_id,))
    conn.commit()
    conn.close()


def set_priority(feed_id, priority):
    conn = get_conn()
    conn.execute("UPDATE feeds SET priority = ? WHERE id = ?", (priority, feed_id))
    conn.commit()
    conn.close()


def enabled_feeds():
    conn = get_conn()
    rows = conn.execute("SELECT * FROM feeds WHERE enabled = 1").fetchall()
    conn.close()
    return rows


def distinct_categories():
    conn = get_conn()
    rows = conn.execute("SELECT DISTINCT category FROM feeds ORDER BY category").fetchall()
    conn.close()
    return [r["category"] for r in rows]


def mark_read(edition_date, slug):
    conn = get_conn()
    conn.execute(
        "INSERT OR IGNORE INTO read_articles (edition_date, slug) VALUES (?, ?)",
        (edition_date, slug),
    )
    conn.commit()
    conn.close()


def get_read_slugs(edition_date):
    conn = get_conn()
    rows = conn.execute(
        "SELECT slug FROM read_articles WHERE edition_date = ?", (edition_date,)
    ).fetchall()
    conn.close()
    return [r["slug"] for r in rows]


def get_setting(key, default=None):
    conn = get_conn()
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else default


def set_setting(key, value):
    conn = get_conn()
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (key, value),
    )
    conn.commit()
    conn.close()
ZEITUNG_FILE_EOF
cat > "$STAGE/app/generator.py" <<'ZEITUNG_FILE_EOF'
import html as html_module
import json
import re
import shutil
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from difflib import SequenceMatcher
from io import BytesIO
from pathlib import Path

import feedparser
import trafilatura
from jinja2 import Environment, FileSystemLoader
from trafilatura.settings import use_config

BASE_DIR = Path(__file__).resolve().parent.parent
OUTPUT_DIR = BASE_DIR / "output"
TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

env = Environment(loader=FileSystemLoader(str(TEMPLATES_DIR)))

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)

# Trafilatura wartet standardmaessig bis zu 30s pro Artikel - bei vielen Feeds
# und ein paar langsamen/toten Seiten summiert sich das schnell auf mehrere
# Minuten. 12s reicht fuer normale Nachrichtenseiten und haelt die
# Gesamtgenerierung in einem vorhersehbaren Rahmen. Ausserdem ein normaler
# Browser-User-Agent statt trafilaturas Standard, da manche Seiten (u.a.
# Google-Redirects) erkennbare Bot-User-Agents mit leeren/degradierten
# Antworten abspeisen.
TRAFILATURA_CONFIG = use_config()
TRAFILATURA_CONFIG.set("DEFAULT", "DOWNLOAD_TIMEOUT", "12")
TRAFILATURA_CONFIG.set("DEFAULT", "USER_AGENTS", USER_AGENT)

PAPER_NAME = "LichtValleyZeitung"

WEEKDAYS_DE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
MONTHS_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]

IMAGE_MAX_BYTES = 6 * 1024 * 1024
IMAGE_MAX_WIDTH = 1000
IMAGE_MIN_WIDTH = 200
IMAGE_MIN_HEIGHT = 150
IMAGE_TIMEOUT = 8


def format_date_de(dt: datetime) -> str:
    return f"{WEEKDAYS_DE[dt.weekday()]}, {dt.day}. {MONTHS_DE[dt.month - 1]} {dt.year}"


UMLAUT_MAP = str.maketrans({
    "ä": "ae", "ö": "oe", "ü": "ue", "Ä": "Ae", "Ö": "Oe", "Ü": "Ue", "ß": "ss",
})


def slugify(text: str, maxlen: int = 60) -> str:
    text = text.translate(UMLAUT_MAP)
    text = re.sub(r"[^\w\s-]", "", text.lower())
    text = re.sub(r"[\s_-]+", "-", text).strip("-")
    return text[:maxlen] or "artikel"


def strip_html(raw_html: str) -> str:
    """Grobe Fallback-Bereinigung, falls trafilatura ein kurzes Snippet nicht mag."""
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", raw_html, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html_module.unescape(text)
    return re.sub(r"\s+", " ", text).strip()


URL_RE = re.compile(r"https?://\S+")


def clean_paragraph(text: str) -> str:
    """Entfernt nackte Links aus Fliesstext (z.B. Bildquellen-URLs, die manche
    Feeds/Seiten als sichtbaren Text statt als Tag-Attribut liefern)."""
    text = URL_RE.sub("", text)
    return re.sub(r"\s+", " ", text).strip()


def feed_summary_html(entry) -> str:
    if entry.get("content"):
        return entry["content"][0].get("value", "") or ""
    return entry.get("summary", "") or entry.get("description", "") or ""


def feed_image(entry):
    media = entry.get("media_content") or entry.get("media_thumbnail")
    if media and media[0].get("url"):
        return media[0]["url"]
    for link in entry.get("links", []):
        if str(link.get("type", "")).startswith("image/") and link.get("href"):
            return link["href"]
    return None


def fetch_candidates(feeds, max_per_feed=8, local_max_per_feed=None):
    """feeds: list of dicts with url/name/category.
    Gibt (candidates, feed_stats) zurueck - feed_stats erlaubt es, in der
    Verwaltung pro Feed zu zeigen, was beim letzten Lauf passiert ist.
    local_max_per_feed: falls gesetzt, gilt fuer Feeds der Rubrik 'Lokales'
    ein hoeheres Limit als fuer alle anderen (siehe 'Alle lokalen
    Schlagzeilen anzeigen' in der Verwaltung)."""
    candidates = []
    seen_links = set()
    feed_stats = []
    for feed in feeds:
        entries_found = 0
        error = None
        parsed = None
        try:
            parsed = feedparser.parse(feed["url"], request_headers={"User-Agent": USER_AGENT})
            entries_found = len(parsed.entries)
            if getattr(parsed, "bozo", False) and not parsed.entries:
                error = str(parsed.get("bozo_exception")) or "Feed konnte nicht gelesen werden"
        except Exception as e:
            error = str(e)

        stat = {
            "url": feed["url"],
            "entries": entries_found,
            "error": error,
            "taken": 0,
            "articles": 0,
            "candidates": [],
        }
        feed_stats.append(stat)

        if parsed is None:
            if error:
                print(f"Feed nicht lesbar ({feed['url']}): {error}")
            continue
        if error:
            print(f"Feed liefert keine Einträge ({feed['url']}): {error}")

        is_local = feed.get("category") == "Lokales"
        limit = local_max_per_feed if (is_local and local_max_per_feed) else max_per_feed

        feed_title = feed.get("name") or getattr(parsed.feed, "title", "") or feed["url"]
        for entry in parsed.entries[:limit]:
            link = entry.get("link")
            if not link or link in seen_links:
                continue
            seen_links.add(link)
            stat["taken"] += 1
            candidates.append(
                {
                    "link": link,
                    "title": entry.get("title", "Ohne Titel"),
                    "category": feed.get("category") or "Allgemein",
                    "source": feed_title,
                    "publisher": (entry.get("source") or {}).get("title"),
                    "feed_url": feed["url"],
                    "published": entry.get("published", ""),
                    "priority": feed.get("priority") or 1,
                    "fallback_html": feed_summary_html(entry),
                    "fallback_image": feed_image(entry),
                }
            )
    print(f"{len(candidates)} Artikel-Kandidaten aus {len(feeds)} Feed(s) gefunden.")
    return candidates, feed_stats


def extract_article(candidate, min_chars=200):
    paragraphs = []
    image_url = candidate.get("fallback_image")
    title = candidate["title"]
    author = None
    full_text = False

    try:
        downloaded = trafilatura.fetch_url(candidate["link"], config=TRAFILATURA_CONFIG)
    except Exception:
        downloaded = None

    if downloaded:
        try:
            result = trafilatura.extract(
                downloaded,
                output_format="json",
                with_metadata=True,
                include_images=True,
                favor_precision=True,
            )
        except Exception:
            result = None
        if result:
            try:
                data = json.loads(result)
            except (json.JSONDecodeError, TypeError):
                data = {}
            text = data.get("text") or ""
            if len(text) >= min_chars:
                paragraphs = [p.strip() for p in text.split("\n") if p.strip()]
                title = data.get("title") or title
                author = data.get("author")
                image_url = data.get("image") or image_url
                full_text = True

    if not paragraphs and candidate.get("fallback_html"):
        # Volltext nicht erreichbar/blockiert (JS-Seite, Paywall, ...) - RSS-eigenen Text nutzen,
        # damit der Artikel trotzdem als Teaser mit Link zum Original erscheint.
        text = strip_html(candidate["fallback_html"])
        if len(text) > 40:
            paragraphs = [text]

    if not paragraphs and "news.google.com" in candidate["link"]:
        # Google News liefert strukturell weder Volltext (nur Redirect-Links,
        # die ohne JS oft ins Leere laufen) noch nutzbare Snippets im Feed
        # selbst. Damit lokale/Google-News-Feeds nicht komplett leer bleiben,
        # zumindest die Schlagzeile mit Link zur Quelle zeigen.
        source = candidate.get("publisher") or candidate.get("source") or "Google News"
        paragraphs = [
            f"Kurzmeldung von {source}. Der vollständige Artikel ist über "
            f"\"Original lesen\" oben erreichbar."
        ]

    if not paragraphs:
        return None, "Kein Text extrahierbar (Seite blockiert Zugriff oder liefert kein Snippet)"

    paragraphs = [clean_paragraph(p) for p in paragraphs]
    paragraphs = [p for p in paragraphs if len(p) >= 15]

    if not paragraphs:
        return None, "Nach Bereinigung kein Text übrig"

    excerpt = paragraphs[0][:220]
    clean = {k: v for k, v in candidate.items() if k not in ("fallback_html", "fallback_image")}
    article = {
        **clean,
        "title": title,
        "excerpt": excerpt,
        "paragraphs": paragraphs,
        "author": author,
        "image_url": image_url,
        "full_text": full_text,
    }
    return article, ("Volltext" if full_text else "Kurzmeldung")


def score_article(article):
    length_score = min(len(article.get("paragraphs", [])), 12)
    priority_score = (article.get("priority") or 1) * 6
    return length_score + priority_score


def download_image(url, out_dir, filename):
    """Laedt ein Bild lokal herunter und speichert es normalisiert als JPEG.
    Liefert einen relativen Pfad (z.B. 'images/artikel-1.jpg') oder None."""
    if not url:
        return None
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=IMAGE_TIMEOUT) as resp:
            content_type = resp.headers.get("Content-Type", "")
            if not content_type.startswith("image/"):
                return None
            raw = resp.read(IMAGE_MAX_BYTES + 1)
            if len(raw) > IMAGE_MAX_BYTES:
                return None
    except Exception:
        return None

    try:
        from PIL import Image

        img = Image.open(BytesIO(raw))
        img.load()

        if img.width < IMAGE_MIN_WIDTH or img.height < IMAGE_MIN_HEIGHT:
            # Zu klein, um ein echtes Artikelfoto zu sein - meist Logo/Icon.
            return None

        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            # Transparenz sauber auf weiss compositen statt sie beim
            # RGB-Konvertieren wegzuwerfen (sonst werden durchsichtige
            # Bereiche schwarz statt weiss).
            rgba = img.convert("RGBA")
            background = Image.new("RGB", rgba.size, (255, 255, 255))
            background.paste(rgba, mask=rgba.split()[-1])
            img = background
        elif img.mode != "RGB":
            img = img.convert("RGB")

        if img.width > IMAGE_MAX_WIDTH:
            ratio = IMAGE_MAX_WIDTH / float(img.width)
            img = img.resize((IMAGE_MAX_WIDTH, max(1, int(img.height * ratio))))
        images_dir = out_dir / "images"
        images_dir.mkdir(exist_ok=True)
        rel_path = f"images/{filename}.jpg"
        img.save(images_dir / f"{filename}.jpg", "JPEG", quality=82)
        return rel_path
    except Exception:
        return None


DUPLICATE_TITLE_THRESHOLD = 0.72


def title_similarity(a: str, b: str) -> float:
    return SequenceMatcher(None, a.lower().strip(), b.lower().strip()).ratio()


def deduplicate_articles(articles, threshold=DUPLICATE_TITLE_THRESHOLD):
    """Entfernt Artikel, deren Titel einem bereits behaltenen Artikel sehr
    aehnlich ist - typischerweise dieselbe dpa/Agentur-Meldung, die ueber
    mehrere Feeds gleichzeitig hereinkommt. Bei einem Duplikat gewinnt der
    hoeher bewertete (Prioritaet/Textlaenge), der Rest wird verworfen."""
    kept = []
    dropped = 0
    for a in sorted(articles, key=score_article, reverse=True):
        is_dup = any(title_similarity(a["title"], k["title"]) >= threshold for k in kept)
        if is_dup:
            dropped += 1
            continue
        kept.append(a)
    if dropped:
        print(f"{dropped} Duplikat(e) anhand aehnlicher Titel entfernt.")
    return kept


def cleanup_old_editions(retention_days=30):
    """Loescht archivierte Ausgaben (inkl. Bilder/PDF), die aelter als
    retention_days sind, damit der Speicher nicht unbegrenzt waechst."""
    if not OUTPUT_DIR.exists():
        return 0
    cutoff = datetime.now().date() - timedelta(days=retention_days)
    removed = 0
    for p in OUTPUT_DIR.iterdir():
        if not p.is_dir() or p.name == "latest":
            continue
        try:
            folder_date = datetime.strptime(p.name, "%Y-%m-%d").date()
        except ValueError:
            continue
        if folder_date < cutoff:
            shutil.rmtree(p, ignore_errors=True)
            removed += 1
    if removed:
        print(f"{removed} alte Ausgabe(n) aelter als {retention_days} Tage aufgeraeumt.")
    return removed


def category_sort_key(cat, order):
    """order: Liste von Rubriknamen in gewuenschter Reihenfolge (Drag&Drop in der
    Verwaltung). Rubriken darin kommen zuerst in dieser Reihenfolge, unbekannte
    Rubriken folgen alphabetisch, 'Allgemein' steht am Ende, sofern nicht explizit
    einsortiert."""
    if cat in order:
        return (0, order.index(cat), "")
    if cat == "Allgemein":
        return (2, 0, "")
    return (1, 0, cat.lower())


def build_edition(
    feeds,
    category_order=None,
    per_category_cap=6,
    max_articles=40,
    max_candidates=80,
    local_unlimited=False,
):
    category_order = category_order or []

    # "Alle lokalen Schlagzeilen anzeigen": Lokal-Feeds werden viel tiefer
    # ausgelesen und in der finalen Ausgabe nicht auf die uebliche
    # Rubrik-Obergrenze gedeckelt.
    local_max_per_feed = 40 if local_unlimited else None
    if local_unlimited:
        max_candidates = max(max_candidates, 140)
        max_articles = max(max_articles, 60)

    candidates, feed_stats = fetch_candidates(feeds, local_max_per_feed=local_max_per_feed)
    candidates = candidates[:max_candidates]
    stats_by_url = {s["url"]: s for s in feed_stats}

    def _process(c):
        article, reason = extract_article(c)
        return c, article, reason

    results = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for c, article, reason in pool.map(_process, candidates):
            results.append((c, article, reason))
            s = stats_by_url.get(c.get("feed_url"))
            if s is not None:
                status = "full" if (article and article.get("full_text")) else ("headline" if article else "rejected")
                s["candidates"].append({"title": c["title"], "link": c["link"], "status": status, "reason": reason})

    extracted = [article for _, article, _ in results if article]
    print(f"{len(extracted)} von {len(candidates)} Kandidaten als Artikel übernommen.")

    for s in feed_stats:
        s["articles"] = sum(1 for cand in s["candidates"] if cand["status"] in ("full", "headline"))

    if not extracted:
        print("Keine Artikel verwertbar - keine Ausgabe erstellt.")
        return {"date": None, "article_count": 0, "section_count": 0, "feed_stats": feed_stats}

    extracted = deduplicate_articles(extracted)

    # Bester Artikel insgesamt wird Aufmacher.
    extracted.sort(key=score_article, reverse=True)
    lead = extracted[0]

    # Nach Rubrik gruppieren (jede Rubrik bekommt spaeter ihre eigene(n) Seite(n)),
    # pro Rubrik gedeckelt, damit keine einzelne Rubrik die ganze Ausgabe dominiert.
    # "Lokales" bekommt bei aktiviertem local_unlimited eine deutlich hoehere
    # Obergrenze, damit tatsaechlich (fast) alle gefundenen Schlagzeilen erscheinen.
    by_category = OrderedDict()
    for a in extracted:
        by_category.setdefault(a["category"], []).append(a)

    capped = []
    for cat, arts in by_category.items():
        cap = 30 if (local_unlimited and cat == "Lokales") else per_category_cap
        capped.extend(arts[:cap])
    if len(capped) > max_articles:
        if local_unlimited:
            # "Alle lokalen Schlagzeilen anzeigen" darf nicht durch die
            # allgemeine Obergrenze wieder zunichte gemacht werden - Lokales
            # bleibt komplett erhalten, nur die uebrigen Rubriken werden gekappt.
            protected = [a for a in capped if a["category"] == "Lokales"]
            rest = [a for a in capped if a["category"] != "Lokales"]
            rest.sort(key=score_article, reverse=True)
            budget = max(0, max_articles - len(protected))
            capped = protected + rest[:budget]
        else:
            capped.sort(key=score_article, reverse=True)
            capped = capped[:max_articles]

    # Finale Rubrik-Gruppen (nach gespeicherter Reihenfolge, sonst alphabetisch,
    # "Allgemein" ans Ende) und finale Artikel-Reihenfolge fuer Blaettern/Vor-Zurueck.
    categories_sorted = sorted(
        {a["category"] for a in capped},
        key=lambda c: category_sort_key(c, category_order),
    )
    sections_all = []
    for cat in categories_sorted:
        arts = sorted([a for a in capped if a["category"] == cat], key=score_article, reverse=True)
        sections_all.append((cat, arts))

    articles = [a for _, arts in sections_all for a in arts]

    for i, a in enumerate(articles):
        a["slug"] = f"artikel-{i + 1}-{slugify(a['title'])}"

    # Rubrik-Sektionen ohne den bereits auf der Titelseite gezeigten Aufmacher,
    # leere Rubriken (nur Aufmacher) werden uebersprungen.
    sections = []
    for cat, arts in sections_all:
        rest = [a for a in arts if a["slug"] != lead["slug"]]
        if rest:
            sections.append((cat, rest))

    now = datetime.now()
    date_display = format_date_de(now)
    time_display = now.strftime("%H:%M")
    edition_date = now.strftime("%Y-%m-%d")
    out_dir = OUTPUT_DIR / edition_date
    out_dir.mkdir(parents=True, exist_ok=True)

    # Sprungmarken fuer die Rubrik-Navigation: jede Rubrik zeigt auf ihren
    # ersten (wichtigsten) Artikel - von dort aus fuehrt Weiterwischen durch
    # die restlichen Artikel dieser Rubrik.
    rubric_nav = [(cat, arts[0]["slug"] + ".html") for cat, arts in sections_all]

    # Bilder parallel herunterladen und lokal ablegen.
    def _fetch_image(a):
        a["image"] = download_image(a.get("image_url"), out_dir, a["slug"])
        a.pop("image_url", None)

    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(_fetch_image, articles))

    front_html = env.get_template("front_page.html").render(
        paper_name=PAPER_NAME,
        date_display=date_display,
        time_display=time_display,
        edition_date=edition_date,
        lead=lead,
        sections=sections,
        rubric_nav=rubric_nav,
    )
    (out_dir / "index.html").write_text(front_html, encoding="utf-8")

    art_tpl = env.get_template("article.html")
    total = len(articles)
    for i, a in enumerate(articles):
        prev_link = articles[i - 1]["slug"] + ".html" if i > 0 else "index.html"
        next_link = articles[i + 1]["slug"] + ".html" if i < len(articles) - 1 else "index.html"
        html = art_tpl.render(
            paper_name=PAPER_NAME,
            a=a,
            prev_link=prev_link,
            next_link=next_link,
            date_display=date_display,
            time_display=time_display,
            edition_date=edition_date,
            page_num=i + 1,
            total_pages=total,
            rubric_nav=rubric_nav,
        )
        (out_dir / f"{a['slug']}.html").write_text(html, encoding="utf-8")

    print_html = env.get_template("print.html").render(
        paper_name=PAPER_NAME,
        date_display=date_display,
        time_display=time_display,
        lead=lead,
        sections=sections,
    )
    pdf_path = out_dir / "zeitung.pdf"
    try:
        from weasyprint import HTML

        HTML(string=print_html, base_url=str(out_dir)).write_pdf(str(pdf_path))
    except Exception as e:  # PDF ist ein Extra, Web-Ausgabe soll trotzdem funktionieren
        print(f"PDF-Erstellung fehlgeschlagen: {e}")

    latest_link = OUTPUT_DIR / "latest"
    if latest_link.is_symlink() or latest_link.exists():
        latest_link.unlink()
    latest_link.symlink_to(out_dir.name)

    return {
        "date": edition_date,
        "article_count": len(articles),
        "section_count": len(sections_all),
        "feed_stats": feed_stats,
    }
ZEITUNG_FILE_EOF
cat > "$STAGE/app/catalog.py" <<'ZEITUNG_FILE_EOF'
# Kuratierte, geprüfte RSS-Feeds für den Anhak-Katalog in der Verwaltung.
# Format: Rubrik -> Liste von (Anzeigename, Feed-URL)
# Alle URLs wurden vor Aufnahme stichprobenartig gegengeprüft (Stand: 2026).

CURATED_FEEDS = {
    "Politik": [
        ("Tagesschau", "https://www.tagesschau.de/xml/rss2"),
        ("n-tv Politik", "https://www.n-tv.de/politik/rss"),
        ("BBC World News (EN)", "http://feeds.bbci.co.uk/news/world/rss.xml"),
    ],
    "Wirtschaft": [
        ("Handelsblatt Finanzen", "https://www.handelsblatt.com/contentexport/feed/finanzen"),
        ("WirtschaftsWoche", "https://www.wiwo.de/contentexport/feed/rss/schlagzeilen"),
        ("Manager Magazin", "https://www.manager-magazin.de/news/index.rss"),
        ("Capital", "https://www.capital.de/rss"),
    ],
    "Technik": [
        ("Heise Online", "https://www.heise.de/newsticker/heise.rdf"),
        ("Golem", "https://rss.golem.de/rss.php?feed=RSS2.0"),
        ("Handelsblatt Technologie", "https://www.handelsblatt.com/contentexport/feed/technologie"),
        ("Hacker News – Frontpage (EN)", "https://hnrss.org/frontpage"),
        ("Ars Technica (EN)", "https://arstechnica.com/feed/"),
        ("The Verge (EN)", "https://www.theverge.com/rss/index.xml"),
        ("Wired (EN)", "https://www.wired.com/feed/rss"),
    ],
    "Sport": [
        ("Sport Bild", "https://sportbild.bild.de/feed/sportbild-home.xml"),
    ],
    "Überregional": [
        ("Zeit Online", "https://newsfeed.zeit.de/index"),
        ("Süddeutsche Zeitung", "https://rss.sueddeutsche.de/rss/Alles"),
    ],
    "Comedy": [
        ("Der Postillon", "https://feeds.feedburner.com/blogspot/rkEL"),
    ],
}
ZEITUNG_FILE_EOF
cat > "$STAGE/app/local_news.py" <<'ZEITUNG_FILE_EOF'
import json
import re
import urllib.parse
import urllib.request

PLZ_RE = re.compile(r"^\d{5}$")
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
TIMEOUT = 8


def resolve_plz_de(plz: str):
    """Loest eine deutsche Postleitzahl zu einem Ortsnamen auf.
    Nutzt die freie zippopotam.us-API (kein API-Key noetig).
    Gibt den Ortsnamen zurueck oder None, wenn nichts gefunden wurde."""
    if not PLZ_RE.match(plz):
        return None
    url = f"https://api.zippopotam.us/de/{plz}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None
    places = data.get("places") or []
    if not places:
        return None
    return places[0].get("place name")


def local_news_feed_url(place: str) -> str:
    """Google-News-Stichwortsuche nach dem Ortsnamen. Mehrteilige Ortsnamen
    werden mit Bindestrich statt Leerzeichen verbunden (z.B. 'Bad-Mergentheim')
    - das behandelt Google erkennbar als eine zusammengehoerige Ortsangabe statt
    als zwei unabhaengige Suchbegriffe und liefert dadurch treffsicherere
    Ergebnisse, gerade bei Orten mit generischen Namensbestandteilen wie 'Bad'."""
    query = urllib.parse.quote(place.replace(" ", "-"))
    return f"https://news.google.com/rss/search?q={query}&hl=de&gl=DE&ceid=DE:de"

ZEITUNG_FILE_EOF
cat > "$STAGE/app/run_generate.py" <<'ZEITUNG_FILE_EOF'
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import db
import generator

RETENTION_DEFAULT = 30


def get_category_order():
    raw = db.get_setting("category_order")
    if not raw:
        return []
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return []


def get_retention_days():
    raw = db.get_setting("retention_days")
    try:
        return max(1, int(raw)) if raw else RETENTION_DEFAULT
    except (TypeError, ValueError):
        return RETENTION_DEFAULT


def get_local_unlimited():
    return db.get_setting("local_unlimited") == "1"


if __name__ == "__main__":
    db.init_db()

    # Dieses Skript laeuft zweimal taeglich (Haupttermin + Wiederholung, siehe
    # zeitung-generate.timer). Ist die heutige Ausgabe schon da, nichts tun -
    # die Wiederholung greift nur, wenn der erste Versuch komplett fehlschlug.
    edition_date = datetime.now().strftime("%Y-%m-%d")
    today_index = generator.OUTPUT_DIR / edition_date / "index.html"
    if today_index.exists():
        print(f"Ausgabe vom {edition_date} existiert bereits - kein erneuter Versuch noetig.")
        sys.exit(0)

    feeds = [dict(f) for f in db.enabled_feeds()]
    result = generator.build_edition(
        feeds, category_order=get_category_order(), local_unlimited=get_local_unlimited()
    )
    db.set_setting("feed_stats", json.dumps(result.get("feed_stats", [])))
    generator.cleanup_old_editions(get_retention_days())

    if result["article_count"] > 0:
        db.set_setting("last_run", result["date"])
        db.set_setting(
            "last_status",
            f"Ausgabe vom {result['date']} mit {result['article_count']} Artikel(n) "
            f"in {result['section_count']} Rubriken erstellt.",
        )
        print(f"Ausgabe {result['date']} erstellt mit {result['article_count']} Artikeln.")
    else:
        db.set_setting(
            "last_status",
            "Es konnte kein Artikel aus den aktiven Feeds geladen werden. "
            "Details je Feed siehst du unten in der Feed-Tabelle.",
        )
        print("Keine Artikel gefunden - keine Ausgabe erstellt.")
ZEITUNG_FILE_EOF
cat > "$STAGE/app/requirements.txt" <<'ZEITUNG_FILE_EOF'
fastapi==0.140.0
uvicorn[standard]==0.51.0
starlette==1.3.1
jinja2==3.1.6
feedparser==6.0.12
trafilatura==2.1.0
weasyprint==69.0
python-multipart==0.0.32
Pillow==12.3.0
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/admin.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LichtValleyZeitung – Verwaltung</title>
<link rel="stylesheet" href="/static/admin.css">
</head>
<body>
<div class="wrap">
  <h1>LichtValleyZeitung <span class="admin-tag">Verwaltung</span></h1>
  <div class="status">
    {% if last_status %}<p class="status-msg">{{ last_status }}</p>{% endif %}
    {% if has_edition %}
      <a href="/lesen">Zeitung ansehen</a> ·
      <a href="/lesen.pdf">PDF herunterladen</a> ·
      <a href="/archiv">Archiv ({{ edition_count }})</a>
    {% else %}
      <p>Noch keine Ausgabe erstellt.</p>
    {% endif %}
    <p class="tablet-hint">Fürs Tablet als Lesezeichen: <code>{{ request.base_url }}lesen</code></p>
  </div>

  <form method="post" action="/generate" class="generate-form" onsubmit="this.querySelector('button').disabled=true; this.querySelector('button').textContent='Erstelle Ausgabe – das kann 1-2 Minuten dauern…';">
    <button type="submit">Zeitung jetzt erstellen</button>
  </form>

  <h2>Rubrik-Reihenfolge</h2>
  <p class="hint">Ziehe die Rubriken in die gewünschte Reihenfolge – oben steht zuerst in der Zeitung.</p>
  {% if categories %}
  <form method="post" action="/settings/category-order" id="order-form">
    <ul id="category-order-list" class="order-list">
      {% for cat in categories %}
      <li draggable="true" data-cat="{{ cat }}">☰ {{ cat }}</li>
      {% endfor %}
    </ul>
    <input type="hidden" name="order" id="order-input">
    <button type="submit">Reihenfolge speichern</button>
  </form>
  {% else %}
  <p class="hint">Sobald Feeds mit Rubriken angelegt sind, kannst du hier ihre Reihenfolge festlegen.</p>
  {% endif %}

  <h2>Lokale Nachrichten</h2>
  <p class="hint">PLZ eingeben, um automatisch eine "Lokales"-Rubrik für deinen Ort einzurichten.</p>
  <form method="post" action="/feeds/local" class="local-form">
    <input type="text" name="plz" placeholder="z.B. 97980" pattern="\d{5}" maxlength="5" required>
    <button type="submit">Lokale Rubrik einrichten</button>
  </form>
  <form method="post" action="/settings/local-unlimited" class="local-unlimited-form">
    <label>
      <input type="checkbox" name="enabled" value="1" {{ "checked" if local_unlimited else "" }} onchange="this.form.submit()">
      Alle lokalen Schlagzeilen anzeigen (auch als reine Kurzmeldung, statt nur die besten 6)
    </label>
  </form>
  <form method="post" action="/feeds/local/repair" class="local-repair-form">
    <button type="submit">Lokale Feed-URLs reparieren</button>
    <span class="hint">Falls "Lokal: ..." keine Artikel mehr liefert - aktualisiert die gespeicherte URL auf das neueste Abfrageformat.</span>
  </form>

  <h2>Feed-Katalog</h2>
  <p class="hint">Geprüfte Feed-Vorschläge zum Anhaken – kein URL-Suchen nötig.</p>
  <form method="post" action="/feeds/catalog-add" class="catalog-form">
    {% for cat, items in catalog.items() %}
    <fieldset class="catalog-group">
      <legend>{{ cat }}</legend>
      {% for name, url in items %}
      <label class="catalog-item">
        <input type="checkbox" name="urls" value="{{ url }}"> {{ name }}
      </label>
      {% endfor %}
    </fieldset>
    {% endfor %}
    <button type="submit">Ausgewählte hinzufügen</button>
  </form>

  <h2>Neuen Feed hinzufügen</h2>
  <form method="post" action="/feeds/add" class="add-feed-form">
    <input type="url" name="url" placeholder="https://beispiel.de/rss" required>
    <input type="text" name="name" placeholder="Name (optional)">
    <input type="text" name="category" placeholder="Rubrik (z.B. Politik)" value="Allgemein">
    <select name="priority">
      <option value="1" selected>Normal</option>
      <option value="2">Wichtig</option>
      <option value="3">Sehr wichtig</option>
    </select>
    <button type="submit">Hinzufügen</button>
  </form>

  <h2>Mehrere Feeds auf einmal importieren</h2>
  <form method="post" action="/feeds/bulk" class="bulk-feed-form">
    <textarea name="feeds_text" rows="6" placeholder="Eine URL pro Zeile. Optional: URL | Name | Rubrik | Priorität(1-3)"></textarea>
    <button type="submit">Alle importieren</button>
  </form>

  <h2>Einstellungen</h2>
  <form method="post" action="/settings/retention" class="retention-form">
    <label for="retention-days">Alte Ausgaben aufbewahren für</label>
    <input type="number" id="retention-days" name="days" min="1" max="365" value="{{ retention_days }}">
    <span>Tage</span>
    <button type="submit">Speichern</button>
  </form>
  <p class="hint">Ältere Ausgaben (inkl. Bilder/PDF) werden nach jeder Generierung automatisch gelöscht.</p>

  <h2>Feeds ({{ feeds|length }})</h2>
  {% if feeds %}
  <table class="feed-table">
    <thead><tr><th>Aktiv</th><th>Name</th><th>Rubrik</th><th>Priorität</th><th>Letzter Lauf</th><th>URL</th><th></th></tr></thead>
    <tbody>
      {% for f in feeds %}
      {% set stat = feed_stats.get(f.url) %}
      <tr>
        <td>
          <form method="post" action="/feeds/{{ f.id }}/toggle">
            <button type="submit" class="toggle {{ 'on' if f.enabled else 'off' }}" title="Ein-/ausschalten">{{ '✓' if f.enabled else '—' }}</button>
          </form>
        </td>
        <td>{{ f.name or f.url }}</td>
        <td>{{ f.category }}</td>
        <td>
          <form method="post" action="/feeds/{{ f.id }}/priority">
            <select name="priority" class="priority-select">
              <option value="1" {{ "selected" if f.priority == 1 else "" }}>Normal</option>
              <option value="2" {{ "selected" if f.priority == 2 else "" }}>Wichtig</option>
              <option value="3" {{ "selected" if f.priority == 3 else "" }}>Sehr wichtig</option>
            </select>
          </form>
        </td>
        <td>
          {% if not stat %}
            <span class="feed-diag">– noch nicht gelaufen</span>
          {% elif stat.error %}
            <span class="feed-diag error" title="{{ stat.error }}">⚠ Fehler</span>
          {% elif stat.entries == 0 %}
            <span class="feed-diag warn">0 Einträge im Feed</span>
          {% elif not stat.candidates %}
            <span class="feed-diag warn">0 von {{ stat.entries }} versucht</span>
          {% else %}
            <details class="feed-detail">
              <summary>
                {% if stat.articles == 0 %}
                  <span class="feed-diag warn">{{ stat.taken }} von {{ stat.entries }} versucht, 0 übernommen</span>
                {% else %}
                  <span class="feed-diag ok">{{ stat.articles }} von {{ stat.taken }} übernommen{% if stat.taken < stat.entries %} ({{ stat.entries }} im Feed insgesamt){% endif %}</span>
                {% endif %}
              </summary>
              <ul class="candidate-list">
                {% for c in stat.candidates %}
                <li class="cand-{{ c.status }}">
                  <span class="cand-badge {{ c.status }}">{% if c.status == 'full' %}Volltext{% elif c.status == 'headline' %}Kurzmeldung{% else %}Abgelehnt{% endif %}</span>
                  <a href="{{ c.link }}" target="_blank" rel="noopener" title="{{ c.reason }}">{{ c.title }}</a>
                </li>
                {% endfor %}
              </ul>
            </details>
          {% endif %}
        </td>
        <td class="url">{{ f.url }}</td>
        <td>
          <form method="post" action="/feeds/{{ f.id }}/delete" onsubmit="return confirm('Feed wirklich entfernen?')">
            <button type="submit" class="del">Entfernen</button>
          </form>
        </td>
      </tr>
      {% endfor %}
    </tbody>
  </table>
  {% else %}
  <p>Noch keine Feeds hinzugefügt.</p>
  {% endif %}
</div>
<script src="/static/admin.js" defer></script>
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/front_page.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{% include "_head_extra.html" %}
<title>{{ paper_name }} – {{ date_display }}</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body data-next="{{ lead.slug }}.html" data-edition="{{ edition_date }}">
<header class="masthead">
  <h1>{{ paper_name }}</h1>
  <div class="masthead-sub">{{ date_display }} · {{ time_display }} Uhr · automatisch erstellte Ausgabe</div>
</header>
{% if rubric_nav %}
<nav class="rubrik-nav">
  {% for cat, link in rubric_nav %}<a href="{{ link }}">{{ cat }}</a>{% endfor %}
</nav>
{% endif %}

<main>
  <article class="lead" data-slug="{{ lead.slug }}">
    {% if lead.image %}<img src="{{ lead.image }}" alt="">{% endif %}
    <span class="kicker">{{ lead.category }}{% if not lead.full_text %} · Kurzmeldung{% endif %}</span>
    <h2><a href="{{ lead.slug }}.html">{{ lead.title }}</a></h2>
    <p class="excerpt{% if not lead.image %} drop-cap{% endif %}">{{ lead.excerpt }}</p>
    <a class="readmore" href="{{ lead.slug }}.html">Weiterlesen →</a>
  </article>

  {% for cat, arts in sections %}
  <section class="rubrik-section">
    <h2 class="rubrik-title">{{ cat }}</h2>
    <div class="teaser-grid">
      {% for t in arts %}
      <article class="teaser" data-slug="{{ t.slug }}">
        {% if t.image %}<img src="{{ t.image }}" alt="">{% endif %}
        {% if not t.full_text %}
        <span class="badge-short">Kurzmeldung</span>
        <h3><a href="{{ t.slug }}.html">{{ t.title }}</a></h3>
        <p class="excerpt teaser-source">{{ t.publisher or t.source }}</p>
        {% else %}
        <h3><a href="{{ t.slug }}.html">{{ t.title }}</a></h3>
        <p class="excerpt">{{ t.excerpt }}</p>
        {% endif %}
      </article>
      {% endfor %}
    </div>
  </section>
  {% endfor %}
</main>

<footer>
  <a href="/">Zur Verwaltung</a> · <a href="/archiv">Archiv</a> · <a href="zeitung.pdf">PDF-Ausgabe</a>
  <p class="swipe-hint">← Zum Lesen nach links wischen</p>
</footer>
{% include "_reader_controls.html" %}
<script src="/static/swipe.js" defer></script>
<script src="/static/read.js" defer></script>
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/article.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{% include "_head_extra.html" %}
<title>{{ a.title }}</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body data-next="{{ next_link }}" data-prev="{{ prev_link }}" data-edition="{{ edition_date }}" data-slug="{{ a.slug }}">
<header class="masthead">
  <h1><a href="index.html">{{ paper_name }}</a></h1>
  <div class="masthead-sub">{{ date_display }} · {{ time_display }} Uhr</div>
</header>
{% if rubric_nav %}
<nav class="rubrik-nav">
  {% for cat, link in rubric_nav %}<a href="{{ link }}"{% if cat == a.category %} class="active"{% endif %}>{{ cat }}</a>{% endfor %}
</nav>
{% endif %}

<main>
  <div class="article-header">
    <span class="kicker">{{ a.category }}</span>
    {% if not a.full_text %}<span class="badge-short">Kurzmeldung – kein Volltext verfügbar</span>{% endif %}
    <h1>{{ a.title }}</h1>
    <div class="byline">{{ a.publisher or a.source }}{% if a.author %} · {{ a.author }}{% endif %} · <a href="{{ a.link }}">Original lesen</a></div>
  </div>

  {% if a.image %}<img class="article-image" src="{{ a.image }}" alt="">{% endif %}

  <div class="article-body">
    {% for p in a.paragraphs %}
    <p>{{ p }}</p>
    {% endfor %}
  </div>

  <div class="article-nav">
    <a href="{{ prev_link }}">← Zurück</a>
    <span class="page-indicator">Seite {{ page_num }} / {{ total_pages }}</span>
    <a href="{{ next_link }}">Weiter →</a>
  </div>
  <p class="swipe-hint">Wischen zum Blättern</p>
</main>
{% include "_reader_controls.html" %}
<script src="/static/swipe.js" defer></script>
<script src="/static/read.js" defer></script>
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/print.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>{{ paper_name }} – {{ date_display }}</title>
<style>
  @page { size: A4; margin: 18mm 16mm; }
  * { box-sizing: border-box; }
  body { font-family: Georgia, "Times New Roman", serif; color: #1a1a1a; font-size: 11pt; line-height: 1.45; }
  .masthead { text-align: center; border-bottom: 3px double #1a1a1a; padding-bottom: 8pt; margin-bottom: 16pt; }
  .masthead h1 { font-size: 30pt; font-weight: normal; margin: 0; }
  .masthead-sub { font-family: Arial, sans-serif; font-size: 9pt; text-transform: uppercase; letter-spacing: 1px; color: #555; }
  .kicker { display: block; font-family: Arial, sans-serif; font-size: 8pt; text-transform: uppercase; letter-spacing: 1px; color: #7a1f1f; margin-bottom: 4pt; }
  .lead img { width: 100%; height: auto; margin-bottom: 8pt; }
  .lead h2 { font-size: 22pt; line-height: 1.15; margin: 0 0 6pt; }
  .lead .article-body { margin-top: 8pt; }
  .toc { margin-top: 18pt; border-top: 1pt solid #1a1a1a; padding-top: 8pt; font-family: Arial, sans-serif; font-size: 9.5pt; }
  .toc-title { text-transform: uppercase; letter-spacing: 1px; color: #7a1f1f; margin-bottom: 4pt; }
  .toc ul { margin: 0; padding-left: 16pt; columns: 2; }
  .rubrik-page { break-before: page; }
  .rubrik-title { font-size: 20pt; font-weight: normal; border-bottom: 3px double #1a1a1a; padding-bottom: 6pt; margin: 0 0 14pt; }
  .article-block { margin-bottom: 18pt; }
  .article-block + .article-block { border-top: 1pt solid #ccc; padding-top: 14pt; }
  .article-block h3 { font-size: 15pt; margin: 0 0 4pt; }
  .byline { font-family: Arial, sans-serif; font-size: 8pt; color: #555; margin-bottom: 6pt; }
  .article-image { width: 100%; height: auto; margin-bottom: 8pt; }
  .article-body { columns: 2; column-gap: 14pt; text-align: justify; font-size: 10.5pt; }
  .article-body p { margin: 0 0 8pt; }
</style>
</head>
<body>
  <div class="masthead">
    <h1>{{ paper_name }}</h1>
    <div class="masthead-sub">{{ date_display }} · {{ time_display }} Uhr · automatisch erstellte Ausgabe</div>
  </div>

  <div class="lead">
    {% if lead.image %}<img src="{{ lead.image }}" alt="">{% endif %}
    <span class="kicker">{{ lead.category }}</span>
    <h2>{{ lead.title }}</h2>
    <div class="article-body">
      {% for p in lead.paragraphs %}<p>{{ p }}</p>{% endfor %}
    </div>
  </div>

  {% if sections %}
  <div class="toc">
    <div class="toc-title">In dieser Ausgabe</div>
    <ul>
      {% for cat, arts in sections %}
      <li>{{ cat }} ({{ arts|length }})</li>
      {% endfor %}
    </ul>
  </div>
  {% endif %}

  {% for cat, arts in sections %}
  <div class="rubrik-page">
    <h2 class="rubrik-title">{{ cat }}</h2>
    {% for a in arts %}
    <div class="article-block">
      <h3>{{ a.title }}</h3>
      <div class="byline">{{ a.publisher or a.source }}{% if a.author %} · {{ a.author }}{% endif %}</div>
      {% if a.image %}<img class="article-image" src="{{ a.image }}" alt="">{% endif %}
      <div class="article-body">
        {% for p in a.paragraphs %}<p>{{ p }}</p>{% endfor %}
      </div>
    </div>
    {% endfor %}
  </div>
  {% endfor %}
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/archiv.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{% include "_head_extra.html" %}
<title>Archiv – LichtValleyZeitung</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<header class="masthead">
  <h1><a href="/lesen">LichtValleyZeitung</a></h1>
  <div class="masthead-sub">Archiv</div>
</header>

<main>
  {% if dates %}
  <ul class="archive-list">
    {% for d in dates %}
    <li>
      <span class="archive-date">{{ d }}</span>
      <a href="/zeitung/{{ d }}/">Lesen</a>
      <a href="/zeitung/{{ d }}/zeitung.pdf">PDF</a>
    </li>
    {% endfor %}
  </ul>
  {% else %}
  <p>Noch keine archivierten Ausgaben vorhanden.</p>
  {% endif %}
</main>

<footer>
  <a href="/lesen">Aktuelle Ausgabe</a> · <a href="/">Zur Verwaltung</a>
</footer>
{% include "_reader_controls.html" %}
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/_head_extra.html" <<'ZEITUNG_FILE_EOF'
<script>(function(){try{var t=localStorage.getItem('zeitung-theme');if(t)document.documentElement.setAttribute('data-theme',t);var s=localStorage.getItem('zeitung-font-scale');if(s)document.documentElement.style.setProperty('--font-scale',s);}catch(e){}})();</script>
<link rel="manifest" href="/static/manifest.json">
<meta name="theme-color" content="#7a1f1f">
<link rel="apple-touch-icon" href="/static/icon-192.png">
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/_reader_controls.html" <<'ZEITUNG_FILE_EOF'
<div class="reader-controls">
  <button id="font-dec" type="button" aria-label="Schrift verkleinern">A−</button>
  <button id="font-inc" type="button" aria-label="Schrift vergrößern">A+</button>
  <button id="theme-toggle" type="button" aria-label="Hell/Dunkel umschalten">◐</button>
</div>
<script src="/static/theme.js" defer></script>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/style.css" <<'ZEITUNG_FILE_EOF'
:root {
  --ink: #1a1a1a;
  --ink-light: #555;
  --rule: #1a1a1a;
  --paper: #fdfdfb;
  --bg: #e9e7e1;
  --accent: #7a1f1f;
  --nav-bg: #1a1a1a;
  --nav-fg: #eee;
  --font-scale: 1;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ink: #e8e6e1;
    --ink-light: #a8a49c;
    --rule: #3a3835;
    --paper: #211f1c;
    --bg: #141312;
    --accent: #e0776b;
    --nav-bg: #000;
    --nav-fg: #ddd;
  }
}

[data-theme="dark"] {
  --ink: #e8e6e1;
  --ink-light: #a8a49c;
  --rule: #3a3835;
  --paper: #211f1c;
  --bg: #141312;
  --accent: #e0776b;
  --nav-bg: #000;
  --nav-fg: #ddd;
}

* { box-sizing: border-box; }

html, body {
  overflow-x: hidden;
  max-width: 100%;
}

body {
  margin: 0;
  background: var(--bg);
  color: var(--ink);
  font-family: Georgia, "Times New Roman", serif;
  line-height: 1.5;
}

.masthead {
  background: var(--paper);
  text-align: center;
  padding: 24px 16px 12px;
  border-bottom: 4px double var(--rule);
}

.masthead h1 {
  margin: 0;
  font-size: clamp(32px, 6vw, 52px);
  letter-spacing: 1px;
  font-weight: 400;
}

.masthead-sub {
  margin-top: 6px;
  font-size: 13px;
  color: var(--ink-light);
  text-transform: uppercase;
  letter-spacing: 1px;
}

.rubrik-nav {
  position: sticky;
  top: 0;
  z-index: 10;
  background: var(--nav-bg);
  display: flex;
  flex-wrap: wrap;
  justify-content: center;
  gap: 2px;
  padding: 0 8px;
}

.rubrik-nav a {
  color: var(--nav-fg);
  text-decoration: none;
  font-family: Arial, sans-serif;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 10px 14px;
  white-space: nowrap;
}

.rubrik-nav a:hover,
.rubrik-nav a.active {
  background: var(--accent);
  color: #fff;
}

main {
  max-width: 920px;
  margin: 0 auto;
  padding: 24px 16px 60px;
  background: var(--paper);
}

.kicker {
  display: inline-block;
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 1px;
  color: var(--accent);
  font-family: Arial, sans-serif;
  margin-bottom: 6px;
}

.badge-short {
  display: block;
  font-size: 11px;
  font-family: Arial, sans-serif;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: #a87c00;
  margin-bottom: 6px;
}

.teaser-source {
  font-size: 13px;
  font-style: italic;
}

.lead {
  border-bottom: 1px solid var(--rule);
  padding-bottom: 24px;
  margin-bottom: 24px;
}

.lead img {
  width: 100%;
  max-height: 420px;
  object-fit: cover;
  display: block;
  margin-bottom: 14px;
}

.lead h2 {
  font-size: clamp(26px, 4vw, 40px);
  margin: 0 0 10px;
  line-height: 1.15;
}

.lead h2 a, h3 a, h1 a {
  color: var(--ink);
  text-decoration: none;
}

.excerpt {
  color: var(--ink-light);
  font-size: calc(17px * var(--font-scale));
  overflow-wrap: break-word;
  word-break: break-word;
}

.excerpt.drop-cap::first-letter {
  float: left;
  font-size: 54px;
  line-height: 44px;
  padding: 4px 8px 0 0;
  font-weight: 400;
  color: var(--ink);
}

.readmore {
  font-family: Arial, sans-serif;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--accent);
  text-decoration: none;
}

.rubrik-section {
  margin-top: 36px;
}

.rubrik-title {
  font-size: 22px;
  font-weight: 400;
  border-bottom: 2px solid var(--rule);
  padding-bottom: 6px;
  margin: 0 0 16px;
}

.teaser-grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
  gap: 24px;
}

.teaser {
  border-top: 1px solid var(--rule);
  padding-top: 12px;
}

.teaser img {
  width: 100%;
  height: 140px;
  object-fit: cover;
  margin-bottom: 8px;
}

.teaser h3 {
  font-size: 18px;
  margin: 0 0 6px;
  line-height: 1.25;
}

.teaser .excerpt {
  font-size: 14px;
}

footer {
  max-width: 920px;
  margin: 0 auto;
  padding: 16px;
  font-family: Arial, sans-serif;
  font-size: 13px;
  text-align: center;
  color: var(--ink-light);
}

footer a { color: var(--ink-light); }

/* Article page */
.article-header {
  border-bottom: 1px solid var(--rule);
  padding-bottom: 16px;
  margin-bottom: 20px;
}

.article-header h1 {
  font-size: clamp(26px, 4vw, 38px);
  line-height: 1.15;
  margin: 8px 0;
}

.byline {
  font-family: Arial, sans-serif;
  font-size: 12px;
  color: var(--ink-light);
}

.article-image {
  width: 100%;
  height: auto;
  margin-bottom: 20px;
}

.article-body {
  font-size: calc(18px * var(--font-scale));
  columns: 1;
}

.article-body p { margin: 0 0 16px; overflow-wrap: break-word; word-break: break-word; }

@media (min-width: 800px) {
  .article-body { columns: 2; column-gap: 32px; }
}

.article-nav {
  display: flex;
  justify-content: space-between;
  align-items: center;
  font-family: Arial, sans-serif;
  font-size: 13px;
  margin-top: 30px;
  padding-top: 16px;
  border-top: 1px solid var(--rule);
}

.article-nav a { color: var(--accent); text-decoration: none; }

.page-indicator {
  color: var(--ink-light);
  font-variant-numeric: tabular-nums;
}

.swipe-hint {
  text-align: center;
  font-family: Arial, sans-serif;
  font-size: 12px;
  color: #999;
  margin-top: 14px;
}

.lead.read,
.teaser.read {
  opacity: 0.5;
}

.reader-controls {
  position: fixed;
  bottom: 16px;
  right: 16px;
  display: flex;
  gap: 6px;
  z-index: 20;
}

.reader-controls button {
  width: 40px;
  height: 40px;
  border-radius: 50%;
  border: 1px solid var(--rule);
  background: var(--paper);
  color: var(--ink);
  font-family: Arial, sans-serif;
  font-size: 14px;
  cursor: pointer;
  box-shadow: 0 2px 6px rgba(0, 0, 0, 0.2);
}

.archive-list {
  list-style: none;
  margin: 0;
  padding: 0;
}

.archive-list li {
  display: flex;
  align-items: center;
  gap: 16px;
  padding: 14px 0;
  border-bottom: 1px solid var(--rule);
  font-family: Arial, sans-serif;
}

.archive-date {
  flex: 1;
  font-family: Georgia, serif;
  font-size: 17px;
}

.archive-list a {
  color: var(--accent);
  text-decoration: none;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
}
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/admin.css" <<'ZEITUNG_FILE_EOF'
:root { --ink:#1a1a1a; --border:#ddd; --accent:#7a1f1f; --bg:#f4f3ef; }
* { box-sizing: border-box; }
body {
  font-family: -apple-system, Arial, sans-serif;
  background: var(--bg);
  color: var(--ink);
  margin: 0;
  padding: 24px 16px 60px;
}
.wrap { max-width: 760px; margin: 0 auto; }
h1 { font-size: 24px; margin-bottom: 4px; }
.admin-tag {
  font-size: 13px;
  font-weight: normal;
  color: #888;
  text-transform: uppercase;
  letter-spacing: 1px;
  vertical-align: middle;
}
h2 { font-size: 16px; margin-top: 32px; border-bottom: 1px solid var(--border); padding-bottom: 6px; }
.status { font-size: 14px; color: #555; margin-bottom: 20px; }
.status a { color: var(--accent); }
.status-msg {
  background: #fff;
  border: 1px solid var(--border);
  border-left: 4px solid var(--accent);
  padding: 10px 12px;
  border-radius: 4px;
  margin: 0 0 8px;
}
.tablet-hint { font-size: 12px; color: #888; margin: 6px 0 0; }
.tablet-hint code { background: #fff; padding: 2px 6px; border-radius: 4px; border: 1px solid var(--border); }
.generate-form button {
  background: var(--accent);
  color: #fff;
  border: none;
  padding: 12px 20px;
  font-size: 15px;
  border-radius: 6px;
  cursor: pointer;
}
.add-feed-form {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 10px;
}
.add-feed-form input {
  flex: 1 1 200px;
  padding: 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 14px;
}
.add-feed-form button {
  padding: 10px 16px;
  border: none;
  background: var(--ink);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}
.bulk-feed-form {
  margin-top: 10px;
}
.bulk-feed-form textarea {
  width: 100%;
  padding: 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 13px;
  font-family: ui-monospace, monospace;
  resize: vertical;
  box-sizing: border-box;
}
.bulk-feed-form button {
  margin-top: 8px;
  padding: 10px 16px;
  border: none;
  background: var(--ink);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}
.add-feed-form select {
  padding: 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 14px;
  background: #fff;
}
.hint { font-size: 13px; color: #888; margin: 4px 0 0; }

.order-list {
  list-style: none;
  margin: 10px 0 0;
  padding: 0;
  max-width: 320px;
}
.order-list li {
  background: #fff;
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 10px 12px;
  margin-bottom: 6px;
  cursor: grab;
  font-size: 14px;
  user-select: none;
}
.order-list li.dragging { opacity: 0.4; }
#order-form button {
  margin-top: 10px;
  padding: 10px 16px;
  border: none;
  background: var(--ink);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}

.local-form {
  display: flex;
  gap: 8px;
  margin-top: 10px;
}
.local-form input {
  width: 120px;
  padding: 10px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 14px;
}
.local-form button {
  padding: 10px 16px;
  border: none;
  background: var(--accent);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}
.local-unlimited-form {
  margin-top: 10px;
  font-size: 13px;
  color: #555;
}
.local-unlimited-form label {
  display: flex;
  align-items: center;
  gap: 6px;
}

.local-repair-form {
  margin-top: 10px;
  display: flex;
  align-items: center;
  gap: 10px;
  flex-wrap: wrap;
}
.local-repair-form button {
  padding: 8px 14px;
  border: 1px solid var(--border);
  background: #fff;
  color: var(--ink);
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
}
.local-repair-form .hint { margin: 0; }

.feed-detail summary {
  cursor: pointer;
  list-style: none;
}
.feed-detail summary::-webkit-details-marker { display: none; }
.candidate-list {
  list-style: none;
  margin: 8px 0 0;
  padding: 8px;
  background: #fff;
  border: 1px solid var(--border);
  border-radius: 6px;
  max-height: 260px;
  overflow-y: auto;
  min-width: 320px;
}
.candidate-list li {
  display: flex;
  align-items: baseline;
  gap: 8px;
  padding: 4px 0;
  font-size: 13px;
}
.candidate-list a {
  color: var(--ink);
  text-decoration: none;
}
.candidate-list a:hover { text-decoration: underline; }
.cand-badge {
  flex-shrink: 0;
  font-size: 10px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  padding: 2px 6px;
  border-radius: 3px;
  color: #fff;
}
.cand-badge.full { background: #2e7d32; }
.cand-badge.headline { background: #b8860b; }
.cand-badge.rejected { background: #999; }
.catalog-form { margin-top: 10px; }
.catalog-group {
  border: 1px solid var(--border);
  border-radius: 6px;
  padding: 10px 14px;
  margin-bottom: 10px;
}
.catalog-group legend {
  font-size: 13px;
  font-weight: bold;
  padding: 0 6px;
}
.catalog-item {
  display: block;
  font-size: 14px;
  padding: 4px 0;
}
.catalog-form button {
  padding: 10px 16px;
  border: none;
  background: var(--accent);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}

.retention-form {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 10px;
  font-size: 14px;
}
.retention-form input[type="number"] {
  width: 70px;
  padding: 8px;
  border: 1px solid var(--border);
  border-radius: 6px;
}
.retention-form button {
  padding: 8px 14px;
  border: none;
  background: var(--ink);
  color: #fff;
  border-radius: 6px;
  cursor: pointer;
}

.priority-select {
  padding: 6px 8px;
  border: 1px solid var(--border);
  border-radius: 6px;
  font-size: 13px;
  background: #fff;
}

.feed-diag {
  font-size: 12px;
  color: #888;
  white-space: nowrap;
}
.feed-diag.ok { color: #2e7d32; }
.feed-diag.warn { color: #b8860b; }
.feed-diag.error { color: #a33; cursor: help; }
  width: 100%;
  border-collapse: collapse;
  margin-top: 12px;
  font-size: 14px;
}
.feed-table th, .feed-table td {
  text-align: left;
  padding: 8px 6px;
  border-bottom: 1px solid var(--border);
  vertical-align: middle;
}
.feed-table td.url {
  color: #777;
  max-width: 260px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
button.toggle {
  width: 32px;
  height: 32px;
  border-radius: 50%;
  border: 1px solid var(--border);
  background: #fff;
  cursor: pointer;
  font-size: 14px;
}
button.toggle.on { background: #2e7d32; color: #fff; border-color: #2e7d32; }
button.toggle.off { color: #999; }
button.del {
  background: none;
  border: none;
  color: #a33;
  cursor: pointer;
  font-size: 13px;
}
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/swipe.js" <<'ZEITUNG_FILE_EOF'
(function () {
  var THRESHOLD = 60;
  var startX = 0;
  var startY = 0;

  document.addEventListener(
    "touchstart",
    function (e) {
      startX = e.touches[0].clientX;
      startY = e.touches[0].clientY;
    },
    { passive: true }
  );

  document.addEventListener(
    "touchend",
    function (e) {
      var dx = e.changedTouches[0].clientX - startX;
      var dy = e.changedTouches[0].clientY - startY;
      if (Math.abs(dx) < THRESHOLD || Math.abs(dx) < Math.abs(dy) * 1.5) return;

      var body = document.body;
      var target = dx < 0 ? body.getAttribute("data-next") : body.getAttribute("data-prev");
      if (target) window.location.href = target;
    },
    { passive: true }
  );

  // Pfeiltasten fuers Testen am Desktop
  document.addEventListener("keydown", function (e) {
    var body = document.body;
    if (e.key === "ArrowLeft") {
      var prev = body.getAttribute("data-prev");
      if (prev) window.location.href = prev;
    } else if (e.key === "ArrowRight") {
      var next = body.getAttribute("data-next");
      if (next) window.location.href = next;
    }
  });
})();
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/theme.js" <<'ZEITUNG_FILE_EOF'
(function () {
  var root = document.documentElement;
  var THEME_KEY = "zeitung-theme";
  var FONT_KEY = "zeitung-font-scale";

  function systemPrefersDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function currentIsDark() {
    var attr = root.getAttribute("data-theme");
    if (attr === "dark") return true;
    if (attr === "light") return false;
    return systemPrefersDark();
  }

  function scale() {
    var v = parseFloat(root.style.getPropertyValue("--font-scale"));
    return isNaN(v) ? 1 : v;
  }

  function setScale(v) {
    v = Math.max(0.8, Math.min(1.6, Math.round(v * 10) / 10));
    root.style.setProperty("--font-scale", v);
    try {
      localStorage.setItem(FONT_KEY, v);
    } catch (e) {}
  }

  document.addEventListener("DOMContentLoaded", function () {
    var themeBtn = document.getElementById("theme-toggle");
    if (themeBtn) {
      themeBtn.addEventListener("click", function () {
        var next = currentIsDark() ? "light" : "dark";
        root.setAttribute("data-theme", next);
        try {
          localStorage.setItem(THEME_KEY, next);
        } catch (e) {}
      });
    }

    var dec = document.getElementById("font-dec");
    var inc = document.getElementById("font-inc");
    if (dec) dec.addEventListener("click", function () { setScale(scale() - 0.1); });
    if (inc) inc.addEventListener("click", function () { setScale(scale() + 0.1); });
  });
})();
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/admin.js" <<'ZEITUNG_FILE_EOF'
(function () {
  function getDragAfterElement(container, y) {
    var els = [].slice.call(container.querySelectorAll("li:not(.dragging)"));
    return els.reduce(
      function (closest, child) {
        var box = child.getBoundingClientRect();
        var offset = y - box.top - box.height / 2;
        if (offset < 0 && offset > closest.offset) {
          return { offset: offset, element: child };
        }
        return closest;
      },
      { offset: -Infinity, element: null }
    ).element;
  }

  document.addEventListener("DOMContentLoaded", function () {
    var list = document.getElementById("category-order-list");
    if (list) {
      var dragEl = null;
      [].slice.call(list.querySelectorAll("li")).forEach(function (li) {
        li.addEventListener("dragstart", function () {
          dragEl = li;
          li.classList.add("dragging");
        });
        li.addEventListener("dragend", function () {
          li.classList.remove("dragging");
        });
      });
      list.addEventListener("dragover", function (e) {
        e.preventDefault();
        if (!dragEl) return;
        var after = getDragAfterElement(list, e.clientY);
        if (after == null) {
          list.appendChild(dragEl);
        } else {
          list.insertBefore(dragEl, after);
        }
      });
    }

    var orderForm = document.getElementById("order-form");
    if (orderForm) {
      orderForm.addEventListener("submit", function () {
        var cats = [].slice.call(list.querySelectorAll("li")).map(function (li) {
          return li.getAttribute("data-cat");
        });
        document.getElementById("order-input").value = cats.join(",");
      });
    }

    [].slice.call(document.querySelectorAll(".priority-select")).forEach(function (sel) {
      sel.addEventListener("change", function () {
        sel.closest("form").submit();
      });
    });
  });
})();
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/read.js" <<'ZEITUNG_FILE_EOF'
(function () {
  document.addEventListener("DOMContentLoaded", function () {
    var edition = document.body.getAttribute("data-edition");
    if (!edition) return;

    var slug = document.body.getAttribute("data-slug");
    if (slug) {
      // Artikelseite: als gelesen markieren (fire-and-forget, kein Fehler stoert das Lesen)
      fetch("/read/" + encodeURIComponent(edition) + "/" + encodeURIComponent(slug), {
        method: "POST",
      }).catch(function () {});
      return;
    }

    // Titelseite: bereits gelesene Artikel dezent markieren
    fetch("/read/" + encodeURIComponent(edition))
      .then(function (r) {
        return r.ok ? r.json() : [];
      })
      .then(function (readSlugs) {
        var set = {};
        readSlugs.forEach(function (s) {
          set[s] = true;
        });
        document.querySelectorAll("[data-slug]").forEach(function (el) {
          if (set[el.getAttribute("data-slug")]) {
            el.classList.add("read");
          }
        });
      })
      .catch(function () {});
  });
})();
ZEITUNG_FILE_EOF
cat > "$STAGE/app/static/manifest.json" <<'ZEITUNG_FILE_EOF'
{
  "name": "LichtValleyZeitung",
  "short_name": "LVZeitung",
  "start_url": "/lesen",
  "scope": "/",
  "display": "standalone",
  "background_color": "#e9e7e1",
  "theme_color": "#7a1f1f",
  "icons": [
    { "src": "/static/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/static/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
ZEITUNG_FILE_EOF
base64 -d > "$STAGE/app/static/icon-192.png" <<'ZEITUNG_B64_EOF'
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
ZEITUNG_B64_EOF
base64 -d > "$STAGE/app/static/icon-512.png" <<'ZEITUNG_B64_EOF'
iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAIAAAB7GkOtAAAVNElEQVR4nO3dd3jW5b3HcbKYggxF
VBSq4igo1uLAWvcuiCIEW2tPtePUUyXIVJaiCIpgCNhlh112BFTEPYur7r2quCciCiIGGSHnn17H
q56fAiHJ/TzP9/X6+8nF57oSePNLntx30dhu3ZoBEE9x6gEApCEAAEEJAEBQAgAQlAAABCUAAEEJ
AEBQAgAQlAAABCUAAEEJAEBQpRvyogteeamxdwDQgCbssNN6X+MJACAoAQAISgAAghIAgKA26IfA
n7MhP1sAoCnV4906ngAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAI
SgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAo
AQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAE
ACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIA
gKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAA
ghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAI
SgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAo
AQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAE
ACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIA
gKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAAghIAgKAEACAoAQAISgAA
ghIAgKAEACAoAQAIqjT1gLwxaeELxSUlqVekV3nIYR++/nrqFU3k9PnztunVK/UK6mPFkiUX77Nf
6hW5zhMAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFBOA91Q
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
qVdkW/XJJ9VnVtSuXZt6CHlPAODziktKyqtmtmzXLvWQbNdNmPjhG2+kXkEhEAD4vMNHjtjua3um
XpHtiauveXLetalXUCAEAP7DTt884IAf/yj1imwfvPbadRNz9D2p5CMBgM+06dRp0KUzcvOix9o1
a6qHDltdU5N6CIWjNPUAmtSof3rj4JfZplfPNp06pV6RraSs7PT581KvoKB4AgAIyhPAhpq08IXc
vAcKoH48AQAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAE5TTQ
DXVuj11ST6DRLbzr7gk77JR6BTQRTwAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkA
QFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAA
QQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAE
JQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCU
AAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFAC
ABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkA
QFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAA
QQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAE
JQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCU
AAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQQkAQFAC
ABCUAAAEJQAAQQkAQFACABCUAAAEJQAAQZXW42MueOWlBt8BQBPzBAAQlAAABCUAAEEJAEBQRWO7
dUu9AYAEPAEABCUAAEEJAEBQAgAQlAAABCUAAEEJAEBQAgAQlAAABCUAAEEJAEBQ/wv74QCIv84A
HgAAAABJRU5ErkJggg==
ZEITUNG_B64_EOF
cat > "$STAGE/systemd/zeitung-generate.timer" <<'ZEITUNG_FILE_EOF'
[Unit]
Description=Taegliche Zeitungserstellung um 05:30 Uhr (mit Wiederholung um 08:00 Uhr bei Totalausfall)

[Timer]
OnCalendar=*-*-* 05:30:00
OnCalendar=*-*-* 08:00:00
Persistent=true

[Install]
WantedBy=timers.target
ZEITUNG_FILE_EOF

tar czf "$STAGE/zeitung-update.tar.gz" -C "$STAGE" app systemd

echo "Uebertrage aktualisierte Dateien in Container $CTID..."
pct push "$CTID" "$STAGE/zeitung-update.tar.gz" /root/zeitung-update.tar.gz

pct exec "$CTID" -- bash -c "
  tar xzf /root/zeitung-update.tar.gz -C /opt/zeitung &&
  /opt/zeitung/venv/bin/pip install -q -r /opt/zeitung/app/requirements.txt &&
  cp /opt/zeitung/systemd/zeitung-generate.timer /etc/systemd/system/ &&
  systemctl daemon-reload &&
  systemctl restart zeitung-generate.timer &&
  systemctl restart zeitung-web.service &&
  sleep 2 &&
  /opt/zeitung/venv/bin/python3 -c \"import urllib.request; urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:8080/feeds/local/repair', method='POST'), timeout=10)\" || true
"

rm -rf "$STAGE"

echo ""
echo "Update eingespielt und Web-Dienst neu gestartet."
echo "Feeds und bisherige Ausgaben blieben erhalten."
