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
            f"Ausgabe vom {result['date']} mit {result['article_count']} Artikel(n) erstellt.",
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
from datetime import datetime
from pathlib import Path

import feedparser
import trafilatura
from jinja2 import Environment, FileSystemLoader

BASE_DIR = Path(__file__).resolve().parent.parent
OUTPUT_DIR = BASE_DIR / "output"
TEMPLATES_DIR = Path(__file__).resolve().parent / "templates"

env = Environment(loader=FileSystemLoader(str(TEMPLATES_DIR)))

WEEKDAYS_DE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
MONTHS_DE = [
    "Januar", "Februar", "März", "April", "Mai", "Juni",
    "Juli", "August", "September", "Oktober", "November", "Dezember",
]


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


def fetch_candidates(feeds, max_per_feed=6):
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
    image = candidate.get("fallback_image")
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
                image = data.get("image") or image
                author = data.get("author")

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
        "image": image,
        "paragraphs": paragraphs,
        "author": author,
    }


def score_article(article):
    s = 0.0
    if article.get("image"):
        s += 3.0
    s += min(len(article.get("paragraphs", [])), 12) * 0.5
    return s


def build_edition(feeds, max_articles=10, max_candidates=40):
    candidates = fetch_candidates(feeds)[:max_candidates]
    articles = []
    for c in candidates:
        art = extract_article(c)
        if art:
            articles.append(art)
        if len(articles) >= max_articles:
            break

    print(f"{len(articles)} von {len(candidates)} Kandidaten als Artikel übernommen.")

    if not articles:
        print("Keine Artikel verwertbar - keine Ausgabe erstellt.")
        return None

    articles.sort(key=score_article, reverse=True)
    lead = articles[0]
    teasers = articles[1:]

    for i, a in enumerate(articles):
        a["slug"] = f"artikel-{i + 1}-{slugify(a['title'])}"

    now = datetime.now()
    date_display = format_date_de(now)
    edition_date = now.strftime("%Y-%m-%d")
    out_dir = OUTPUT_DIR / edition_date
    out_dir.mkdir(parents=True, exist_ok=True)

    front_html = env.get_template("front_page.html").render(
        date_display=date_display, lead=lead, teasers=teasers
    )
    (out_dir / "index.html").write_text(front_html, encoding="utf-8")

    art_tpl = env.get_template("article.html")
    for i, a in enumerate(articles):
        prev_link = articles[i - 1]["slug"] + ".html" if i > 0 else "index.html"
        next_link = articles[i + 1]["slug"] + ".html" if i < len(articles) - 1 else "index.html"
        html = art_tpl.render(a=a, prev_link=prev_link, next_link=next_link, date_display=date_display)
        (out_dir / f"{a['slug']}.html").write_text(html, encoding="utf-8")

    print_html = env.get_template("print.html").render(
        date_display=date_display, lead=lead, articles=articles
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

    return {"date": edition_date, "article_count": len(articles)}
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
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/admin.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Zeitungs-Verwaltung</title>
<link rel="stylesheet" href="/static/admin.css">
</head>
<body>
<div class="wrap">
  <h1>Zeitungs-Verwaltung</h1>
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

  <form method="post" action="/generate" class="generate-form">
    <button type="submit">Zeitung jetzt erstellen</button>
  </form>

  <h2>Neuen Feed hinzufügen</h2>
  <form method="post" action="/feeds/add" class="add-feed-form">
    <input type="url" name="url" placeholder="https://beispiel.de/rss" required>
    <input type="text" name="name" placeholder="Name (optional)">
    <input type="text" name="category" placeholder="Rubrik (z.B. Politik)" value="Allgemein">
    <button type="submit">Hinzufügen</button>
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
<title>Die Tageszeitung – {{ date_display }}</title>
<link rel="stylesheet" href="/static/style.css">
</head>
<body>
<header class="masthead">
  <h1>Die Tageszeitung</h1>
  <div class="masthead-sub">{{ date_display }} · automatisch erstellte Ausgabe</div>
</header>

<main>
  <article class="lead">
    {% if lead.image %}<img src="{{ lead.image }}" alt="">{% endif %}
    <span class="kicker">{{ lead.category }}</span>
    <h2><a href="{{ lead.slug }}.html">{{ lead.title }}</a></h2>
    <p class="excerpt">{{ lead.excerpt }}</p>
    <a class="readmore" href="{{ lead.slug }}.html">Weiterlesen →</a>
  </article>

  <div class="teaser-grid">
    {% for t in teasers %}
    <article class="teaser">
      {% if t.image %}<img src="{{ t.image }}" alt="">{% endif %}
      <span class="kicker">{{ t.category }}</span>
      <h3><a href="{{ t.slug }}.html">{{ t.title }}</a></h3>
      <p class="excerpt">{{ t.excerpt }}</p>
    </article>
    {% endfor %}
  </div>
</main>

<footer>
  <a href="/">Zur Verwaltung</a> · <a href="zeitung.pdf">PDF-Ausgabe</a>
</footer>
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
<body>
<header class="masthead">
  <h1><a href="index.html">Die Tageszeitung</a></h1>
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
    <a href="index.html">Titelseite</a>
    <a href="{{ next_link }}">Weiter →</a>
  </div>
</main>
</body>
</html>
ZEITUNG_FILE_EOF
cat > "$STAGE/app/templates/print.html" <<'ZEITUNG_FILE_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<title>Die Tageszeitung – {{ date_display }}</title>
<style>
  @page { size: A4; margin: 18mm 16mm; }
  * { box-sizing: border-box; }
  body { font-family: Georgia, "Times New Roman", serif; color: #1a1a1a; font-size: 11pt; line-height: 1.45; }
  .masthead { text-align: center; border-bottom: 3px double #1a1a1a; padding-bottom: 8pt; margin-bottom: 16pt; }
  .masthead h1 { font-size: 30pt; font-weight: normal; margin: 0; }
  .masthead-sub { font-family: Arial, sans-serif; font-size: 9pt; text-transform: uppercase; letter-spacing: 1px; color: #555; }
  .kicker { display: block; font-family: Arial, sans-serif; font-size: 8pt; text-transform: uppercase; letter-spacing: 1px; color: #7a1f1f; margin-bottom: 4pt; }
  .lead { border-bottom: 1pt solid #1a1a1a; padding-bottom: 14pt; margin-bottom: 14pt; }
  .lead img { width: 100%; height: auto; margin-bottom: 8pt; }
  .lead h2 { font-size: 22pt; line-height: 1.15; margin: 0 0 6pt; }
  .lead .excerpt { font-size: 12pt; color: #444; }
  .front-grid { display: flex; flex-wrap: wrap; gap: 12pt; }
  .front-grid .teaser { width: 47%; border-top: 1pt solid #1a1a1a; padding-top: 6pt; }
  .front-grid .teaser h3 { font-size: 12pt; margin: 0 0 4pt; }
  .front-grid .teaser .excerpt { font-size: 9.5pt; color: #444; }
  .article-page { break-before: page; }
  .article-header { border-bottom: 1pt solid #1a1a1a; padding-bottom: 8pt; margin-bottom: 12pt; }
  .article-header h1 { font-size: 20pt; margin: 4pt 0; line-height: 1.15; }
  .byline { font-family: Arial, sans-serif; font-size: 8pt; color: #555; }
  .article-image { width: 100%; height: auto; margin-bottom: 10pt; }
  .article-body { columns: 2; column-gap: 14pt; text-align: justify; }
  .article-body p { margin: 0 0 8pt; }
</style>
</head>
<body>
  <div class="masthead">
    <h1>Die Tageszeitung</h1>
    <div class="masthead-sub">{{ date_display }} · automatisch erstellte Ausgabe</div>
  </div>

  <div class="lead">
    {% if lead.image %}<img src="{{ lead.image }}" alt="">{% endif %}
    <span class="kicker">{{ lead.category }}</span>
    <h2>{{ lead.title }}</h2>
    <p class="excerpt">{{ lead.excerpt }}</p>
  </div>

  <div class="front-grid">
    {% for a in articles[1:] %}
    <div class="teaser">
      <span class="kicker">{{ a.category }}</span>
      <h3>{{ a.title }}</h3>
      <p class="excerpt">{{ a.excerpt }}</p>
    </div>
    {% endfor %}
  </div>

  {% for a in articles %}
  <div class="article-page">
    <div class="article-header">
      <span class="kicker">{{ a.category }}</span>
      <h1>{{ a.title }}</h1>
      <div class="byline">{{ a.source }}{% if a.author %} · {{ a.author }}{% endif %}</div>
    </div>
    {% if a.image %}<img class="article-image" src="{{ a.image }}" alt="">{% endif %}
    <div class="article-body">
      {% for p in a.paragraphs %}
      <p>{{ p }}</p>
      {% endfor %}
    </div>
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
  height: auto;
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

.readmore {
  font-family: Arial, sans-serif;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  color: var(--accent);
  text-decoration: none;
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
  font-family: Arial, sans-serif;
  font-size: 13px;
  margin-top: 30px;
  padding-top: 16px;
  border-top: 1px solid var(--rule);
}

.article-nav a { color: var(--accent); text-decoration: none; }
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
