# Zeitungs-LXC für Proxmox

Erstellt einen einzelnen LXC-Container, der aus deinen RSS-Feeds automatisch
eine tägliche "Zeitung" generiert – als Web-App zum Blättern (Tablet-tauglich)
und als PDF zum Download. Kein separater RSS-Aggregator nötig: Feeds pflegst
du direkt in der eingebauten Verwaltungsoberfläche.

## Installation

Auf der Proxmox-Host-Shell (z.B. über die Weboberfläche → Datacenter → dein
Node → Shell):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/proxmox-zeitung/main/install-newspaper-lxc.sh)"
```

Das Skript fragt nach Container-ID, Hostname, Storage, Netzwerk-Bridge,
RAM/CPU/Disk (überall sind Standardwerte per Enter übernehmbar), erstellt
dann einen Debian-12-LXC, installiert alle Abhängigkeiten und richtet zwei
systemd-Dienste ein. Am Ende zeigt es dir die Adresse der Verwaltungsseite,
z.B. `http://192.168.1.50:8080`.

Dauer: ca. 3–6 Minuten, je nach Internetverbindung des Proxmox-Hosts.

## Benutzung

1. `http://<Container-IP>:8080` im Browser öffnen (auf dem Tablet als
   Homescreen-Icon speicherbar für App-Gefühl).
2. Oben RSS-Feed-Links einfügen (URL + optionaler Name + Rubrik, z.B.
   "Politik", "Sport", "Lokales") und mit "Hinzufügen" bestätigen.
3. Jeder Feed lässt sich über den Kreis-Button links in der Liste
   ein-/ausschalten (An = grün) – so bestimmst du per Klick, welche Feeds
   in die nächste Ausgabe einfließen.
4. "Zeitung jetzt erstellen" klicken für eine sofortige Ausgabe, oder
   einfach warten: **jeden Morgen um 05:30 Uhr** wird automatisch eine neue
   Ausgabe erstellt.
5. Über die Links "Zeitung ansehen" / "PDF herunterladen" gelangst du zur
   aktuellen Ausgabe.

## Wie die Auswahl funktioniert

Aus allen aktiven Feeds werden die neuesten Artikel geladen, der Volltext
und ein Titelbild extrahiert (via `trafilatura`). Der Artikel mit Bild und
den meisten Absätzen wird automatisch zum Aufmacher, die übrigen werden als
Teaser auf der Titelseite angeordnet; ein Klick öffnet die Innenseite mit
dem vollständigen Artikel.

## Anpassen

- **Uhrzeit ändern:** `/etc/systemd/system/zeitung-generate.timer` im
  Container bearbeiten (`OnCalendar=`), danach
  `systemctl daemon-reload && systemctl restart zeitung-generate.timer`.
- **Zeitungsname/Layout:** `/opt/zeitung/app/templates/*.html` und
  `/opt/zeitung/app/static/*.css` im Container anpassen – Änderungen wirken
  sofort bei der nächsten Ausgabe (Web-Dienst neu starten reicht bei reinen
  Template-Änderungen sogar nicht, PDF/HTML werden bei jeder Generierung neu
  geschrieben).
- **Anzahl Artikel je Ausgabe:** `max_articles` in
  `/opt/zeitung/app/generator.py`, Funktion `build_edition`.
- **Dienste neu starten:**
  `systemctl restart zeitung-web` bzw. manuell erzeugen mit
  `systemctl start zeitung-generate.service`.

## Bestandteile im Container

- `/opt/zeitung/app` – FastAPI-Anwendung (Verwaltung + Auslieferung)
- `/opt/zeitung/venv` – Python-Umgebung
- `/opt/zeitung/data/zeitung.db` – SQLite mit deinen Feeds
- `/opt/zeitung/output/<Datum>/` – archivierte Ausgaben (HTML + PDF),
  `output/latest` zeigt auf die aktuelle
- `zeitung-web.service` – liefert die Verwaltungsseite & Zeitung auf Port 8080
- `zeitung-generate.timer` / `.service` – tägliche automatische Erstellung
