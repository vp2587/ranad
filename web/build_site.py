"""Build the installable web app in docs/ (served by GitHub Pages) from web/ranad.html.

Run from the repository root after changing web/ranad.html:

    python3 web/build_site.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "web" / "ranad.html"
SITE = ROOT / "docs"
ICON = ROOT / "Ranad" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"

HEAD = """<!doctype html>
<html lang="th">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, user-scalable=no">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="ระนาด">
<meta name="theme-color" content="#120405">
<link rel="manifest" href="manifest.webmanifest">
<link rel="apple-touch-icon" href="apple-touch-icon.png">
<link rel="icon" type="image/png" href="icon-192.png">
<style>
  *, *::before, *::after { box-sizing: border-box; }
  :root { padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px); }
  html, body { margin: 0; }
  [hidden] { display: none !important; }
</style>
"""

REGISTER_WORKER = """<script>
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
  }
</script>
"""


def main():
    page = SOURCE.read_text(encoding="utf-8")
    split = page.index('<div class="app">')
    head_part, body_part = page[:split], page[split:]
    html = HEAD + head_part + "</head>\n<body>\n" + body_part + REGISTER_WORKER + "</body>\n</html>\n"
    SITE.mkdir(exist_ok=True)
    (SITE / "index.html").write_text(html, encoding="utf-8")

    icon = Image.open(ICON).convert("RGB")
    for name, size in [("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512)]:
        icon.resize((size, size), Image.LANCZOS).save(SITE / name, optimize=True)


if __name__ == "__main__":
    main()
