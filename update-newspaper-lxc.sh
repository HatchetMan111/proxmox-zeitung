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
mkdir -p "$STAGE/app/templates" "$STAGE/app/static"

cat > "$STAGE/app/main.py" <<'ZEITUNG_FILE_EOF'
from pathlib import Path

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

import db
import generator

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = BASE_DIR.parent / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Zeitung")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

db.init_db()


def has_edition() -> bool:
    return (OUTPUT_DIR / "latest").exists()


@app.get("/", response_class=HTMLResponse)
def admin(request: Request):
    feeds = db.list_feeds()
    last_status = db.get_setting("last_status")
    return templates.TemplateResponse(
        request,
        "admin.html",
        {"feeds": feeds, "last_status": last_status, "has_edition": has_edition()},
    )


@app.post("/feeds/add")
def feeds_add(url: str = Form(...), name: str = Form(""), category: str = Form("Allgemein")):
    db.add_feed(url.strip(), name.strip(), category.strip() or "Allgemein")
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
        db.add_feed(url, name, category or "Allgemein")
        added += 1
    db.set_setting("last_status", f"{added} Feed(s) importiert.")
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/{feed_id}/toggle")
def feeds_toggle(feed_id: int):
    db.toggle_feed(feed_id)
    return RedirectResponse("/", status_code=303)


@app.post("/feeds/{feed_id}/delete")
def feeds_delete(feed_id: int):
    db.delete_feed(feed_id)
    return RedirectResponse("/", status_code=303)


@app.post("/generate")
def generate_now():
    feeds = [dict(f) for f in db.enabled_feeds()]
    if not feeds:
        db.set_setting("last_status", "Keine aktiven Feeds - bitte zuerst einen Feed hinzufügen und anhaken.")
        return RedirectResponse("/", status_code=303)

    result = generator.build_edition(feeds)
    if result:
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
            "Prüfe, ob die Feed-URLs korrekt sind und erreichbar sind (siehe journalctl -u zeitung-web -f).",
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


# Erst NACH den eigenen Routen mounten, damit /lesen nicht vom StaticFiles-Mount verschluckt wird.
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
    conn.commit()
    conn.close()


def list_feeds():
    conn = get_conn()
    rows = conn.execute("SELECT * FROM feeds ORDER BY category, name").fetchall()
    conn.close()
    return rows


def add_feed(url, name, category):
    conn = get_conn()
    conn.execute(
        "INSERT OR IGNORE INTO feeds (url, name, category) VALUES (?, ?, ?)",
        (url, name or None, category or "Allgemein"),
    )
    conn.commit()
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


def enabled_feeds():
    conn = get_conn()
    rows = conn.execute("SELECT * FROM feeds WHERE enabled = 1").fetchall()
    conn.close()
    return rows


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
import urllib.request
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from io import BytesIO
from pathlib import Path

import feedparser
import trafilatura
from jinja2 import Environment, FileSystemLoader

BASE_DIR = Path(__file__).resolve().parent.parent
OUTPUT_DIR = BASE_DIR / "output"
TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

env = Environment(loader=FileSystemLoader(str(TEMPLATES_DIR)))

PAPER_NAME = "LichtValleyZeitung"

WEEKDAYS_DE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
MONTHS_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]

IMAGE_MAX_BYTES = 6 * 1024 * 1024
IMAGE_MAX_WIDTH = 1000
IMAGE_TIMEOUT = 8
USER_AGENT = "Mozilla/5.0 (compatible; LichtValleyZeitung/1.0; +https://example.invalid)"


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


def fetch_candidates(feeds, max_per_feed=8):
    """feeds: list of dicts with url/name/category"""
    candidates = []
    seen_links = set()
    for feed in feeds:
        try:
            parsed = feedparser.parse(feed["url"])
        except Exception as e:
            print(f"Feed nicht lesbar ({feed['url']}): {e}")
            continue
        if getattr(parsed, "bozo", False) and not parsed.entries:
            print(f"Feed liefert keine Einträge ({feed['url']}): {parsed.get('bozo_exception')}")
        feed_title = feed.get("name") or getattr(parsed.feed, "title", "") or feed["url"]
        for entry in parsed.entries[:max_per_feed]:
            link = entry.get("link")
            if not link or link in seen_links:
                continue
            seen_links.add(link)
            candidates.append(
                {
                    "link": link,
                    "title": entry.get("title", "Ohne Titel"),
                    "category": feed.get("category") or "Allgemein",
                    "source": feed_title,
                    "published": entry.get("published", ""),
                    "fallback_html": feed_summary_html(entry),
                    "fallback_image": feed_image(entry),
                }
            )
    print(f"{len(candidates)} Artikel-Kandidaten aus {len(feeds)} Feed(s) gefunden.")
    return candidates


def extract_article(candidate, min_chars=200):
    paragraphs = []
    image_url = candidate.get("fallback_image")
    title = candidate["title"]
    author = None

    try:
        downloaded = trafilatura.fetch_url(candidate["link"])
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

    if not paragraphs and candidate.get("fallback_html"):
        # Volltext nicht erreichbar/blockiert (JS-Seite, Paywall, ...) - RSS-eigenen Text nutzen,
        # damit der Artikel trotzdem als Teaser mit Link zum Original erscheint.
        text = strip_html(candidate["fallback_html"])
        if len(text) > 40:
            paragraphs = [text]

    if not paragraphs:
        print(f"Kein nutzbarer Text für: {candidate['link']}")
        return None

    excerpt = paragraphs[0][:220]
    clean = {k: v for k, v in candidate.items() if k not in ("fallback_html", "fallback_image")}
    return {
        **clean,
        "title": title,
        "excerpt": excerpt,
        "paragraphs": paragraphs,
        "author": author,
        "image_url": image_url,
    }


def score_article(article):
    return min(len(article.get("paragraphs", [])), 12)


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
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        elif img.mode == "L":
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


def build_edition(feeds, per_category_cap=6, max_articles=40, max_candidates=80):
    candidates = fetch_candidates(feeds)[:max_candidates]

    extracted = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(extract_article, c) for c in candidates]
        for fut in as_completed(futures):
            art = fut.result()
            if art:
                extracted.append(art)

    print(f"{len(extracted)} von {len(candidates)} Kandidaten als Artikel übernommen.")

    if not extracted:
        print("Keine Artikel verwertbar - keine Ausgabe erstellt.")
        return None

    # Bester Artikel insgesamt wird Aufmacher.
    extracted.sort(key=score_article, reverse=True)
    lead = extracted[0]

    # Nach Rubrik gruppieren (jede Rubrik bekommt spaeter ihre eigene(n) Seite(n)),
    # pro Rubrik gedeckelt, damit keine einzelne Rubrik die ganze Ausgabe dominiert.
    by_category = OrderedDict()
    for a in extracted:
        by_category.setdefault(a["category"], []).append(a)

    capped = []
    for arts in by_category.values():
        capped.extend(arts[:per_category_cap])
    if len(capped) > max_articles:
        capped.sort(key=score_article, reverse=True)
        capped = capped[:max_articles]

    # Finale Rubrik-Gruppen (alphabetisch, "Allgemein" ans Ende) und finale
    # Artikel-Reihenfolge fuer Blaettern/Vor-Zurueck.
    categories_sorted = sorted(
        {a["category"] for a in capped},
        key=lambda c: (c == "Allgemein", c.lower()),
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
    edition_date = now.strftime("%Y-%m-%d")
    out_dir = OUTPUT_DIR / edition_date
    out_dir.mkdir(parents=True, exist_ok=True)

    # Bilder parallel herunterladen und lokal ablegen.
    def _fetch_image(a):
        a["image"] = download_image(a.get("image_url"), out_dir, a["slug"])
        a.pop("image_url", None)

    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(_fetch_image, articles))

    front_html = env.get_template("front_page.html").render(
        paper_name=PAPER_NAME, date_display=date_display, lead=lead, sections=sections
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
            page_num=i + 1,
            total_pages=total,
        )
        (out_dir / f"{a['slug']}.html").write_text(html, encoding="utf-8")

    print_html = env.get_template("print.html").render(
        paper_name=PAPER_NAME, date_display=date_display, lead=lead, sections=sections
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
    }
ZEITUNG_FILE_EOF
cat > "$STAGE/app/run_generate.py" <<'ZEITUNG_FILE_EOF'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import db
import generator

if __name__ == "__main__":
    db.init_db()
    feeds = [dict(f) for f in db.enabled_feeds()]
    result = generator.build_edition(feeds)
    if result:
        db.set_setting("last_run", result["date"])
        print(f"Ausgabe {result['date']} erstellt mit {result['article_count']} Artikeln.")
    else:
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
      <a href="/lesen.pdf">PDF herunterladen</a>
    {% else %}
      <p>Noch keine Ausgabe erstellt.</p>
    {% endif %}
    <p class="tablet-hint">Fürs Tablet als Lesezeichen: <code>{{ request.base_url }}lesen</code></p>
  </div>

  <form method="post" action="/generate" class="generate-form" onsubmit="this.querySelector('button').disabled=true; this.querySelector('button').textContent='Erstelle Ausgabe – das kann 1-2 Minuten dauern…';">
    <button type="submit">Zeitung jetzt erstellen</button>
  </form>

  <h2>Neuen Feed hinzufügen</h2>
  <form method="post" action="/feeds/add" class="add-feed-form">
    <input type="url" name="url" placeholder="https://beispiel.de/rss" required>
    <input type="text" name="name" placeholder="Name (optional)">
    <input type="text" name="category" placeholder="Rubrik (z.B. Politik)" value="Allgemein">
    <button type="submit">Hinzufügen</button>
  </form>

  <h2>Mehrere Feeds auf einmal importieren</h2>
  <form method="post" action="/feeds/bulk" class="bulk-feed-form">
    <textarea name="feeds_text" rows="6" placeholder="Eine URL pro Zeile. Optional mit Name und Rubrik: URL | Name | Rubrik"></textarea>
    <button type="submit">Alle importieren</button>
  </form>

  <h2>Feeds ({{ feeds|length }})</h2>
  {% if feeds %}
  <table class="feed-table">
    <thead><tr><th>Aktiv</th><th>Name</th><th>Rubrik</th><th>URL</th><th></th></tr></thead>
    <tbody>
      {% for f in feeds %}
      <tr>
        <td>
          <form method="post" action="/feeds/{{ f.id }}/toggle">
            <button type="submit" class="toggle {{ 'on' if f.enabled else 'off' }}" title="Ein-/ausschalten">{{ '✓' if f.enabled else '—' }}</button>
          </form>
        </td>
        <td>{{ f.name or f.url }}</td>
        <td>{{ f.category }}</td>
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
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/front_page.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ paper_name }} – {{ date_display }}</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body data-next="{{ lead.slug }}.html">
<header class="masthead">
  <h1>{{ paper_name }}</h1>
  <div class="masthead-sub">{{ date_display }} · automatisch erstellte Ausgabe</div>
</header>

<main>
  <article class="lead">
    {% if lead.image %}<img src="{{ lead.image }}" alt="">{% endif %}
    <span class="kicker">{{ lead.category }}</span>
    <h2><a href="{{ lead.slug }}.html">{{ lead.title }}</a></h2>
    <p class="excerpt{% if not lead.image %} drop-cap{% endif %}">{{ lead.excerpt }}</p>
    <a class="readmore" href="{{ lead.slug }}.html">Weiterlesen →</a>
  </article>

  {% for cat, arts in sections %}
  <section class="rubrik-section">
    <h2 class="rubrik-title">{{ cat }}</h2>
    <div class="teaser-grid">
      {% for t in arts %}
      <article class="teaser">
        {% if t.image %}<img src="{{ t.image }}" alt="">{% endif %}
        <h3><a href="{{ t.slug }}.html">{{ t.title }}</a></h3>
        <p class="excerpt">{{ t.excerpt }}</p>
      </article>
      {% endfor %}
    </div>
  </section>
  {% endfor %}
</main>

<footer>
  <a href="/">Zur Verwaltung</a> · <a href="zeitung.pdf">PDF-Ausgabe</a>
  <p class="swipe-hint">← Zum Lesen nach links wischen</p>
</footer>
<script src="/static/swipe.js" defer></script>
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/article.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ a.title }}</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body data-next="{{ next_link }}" data-prev="{{ prev_link }}">
<header class="masthead">
  <h1><a href="index.html">{{ paper_name }}</a></h1>
  <div class="masthead-sub">{{ date_display }}</div>
</header>

<main>
  <div class="article-header">
    <span class="kicker">{{ a.category }}</span>
    <h1>{{ a.title }}</h1>
    <div class="byline">{{ a.source }}{% if a.author %} · {{ a.author }}{% endif %} · <a href="{{ a.link }}">Original lesen</a></div>
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
<script src="/static/swipe.js" defer></script>
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
    <div class="masthead-sub">{{ date_display }} · automatisch erstellte Ausgabe</div>
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
      <div class="byline">{{ a.source }}{% if a.author %} · {{ a.author }}{% endif %}</div>
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
cat > "$STAGE/app/static/style.css" <<'ZEITUNG_FILE_EOF'
:root {
  --ink: #1a1a1a;
  --ink-light: #555;
  --rule: #1a1a1a;
  --paper: #fdfdfb;
  --accent: #7a1f1f;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: #e9e7e1;
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
  font-size: 17px;
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
  font-size: 18px;
  columns: 1;
}

.article-body p { margin: 0 0 16px; }

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
table.feed-table {
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

tar czf "$STAGE/zeitung-update.tar.gz" -C "$STAGE" app

echo "Uebertrage aktualisierte Dateien in Container $CTID..."
pct push "$CTID" "$STAGE/zeitung-update.tar.gz" /root/zeitung-update.tar.gz

pct exec "$CTID" -- bash -c "
  tar xzf /root/zeitung-update.tar.gz -C /opt/zeitung &&
  /opt/zeitung/venv/bin/pip install -q -r /opt/zeitung/app/requirements.txt &&
  systemctl restart zeitung-web.service
"

rm -rf "$STAGE"

echo ""
echo "Update eingespielt und Web-Dienst neu gestartet."
echo "Feeds und bisherige Ausgaben blieben erhalten."
