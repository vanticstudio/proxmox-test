#!/usr/bin/env python3
"""Finish a stress-test HTML report on the LOCAL computer (macOS, Linux or Windows).

Usage:
    finish_report.py --html REPORT.html [--pdf OUT.pdf] [--no-open] [--no-embed-fonts]

Steps:
  1. Make the HTML self-contained: download the Google Fonts stylesheet named by
     <link data-embed-fonts ... href="https://fonts.googleapis.com/...">, keep only the
     latin @font-face blocks, inline every woff2 as a data: URI, replace the <link>
     with a <style> block and drop the fonts preconnect links. On any network error
     the file is left working with its fallback font stacks.
  2. Make a PDF (default: same name as the HTML, .pdf) from a temporary print copy in
     which every <details> is open. Renderers tried in order: Google Chrome, Chromium,
     Microsoft Edge, Brave (headless), wkhtmltopdf, WeasyPrint.
  3. Open the HTML in the default browser (skip with --no-open).
  4. Print a summary of the Markdown, HTML and PDF files.

Python 3 standard library only.
"""
import argparse
import base64
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
TIMEOUT = 20

LINK_RE = re.compile(r"<link\b[^>]*\bdata-embed-fonts\b[^>]*>", re.I)
HREF_RE = re.compile(r"""\bhref\s*=\s*(["'])(.*?)\1""", re.I | re.S)
PRECONNECT_RE = re.compile(
    r"""[ \t]*<link\b[^>]*\brel\s*=\s*["']?preconnect["']?[^>]*"""
    r"""fonts\.(?:googleapis|gstatic)\.com[^>]*>[ \t]*\r?\n?""", re.I)
PRECONNECT_RE2 = re.compile(
    r"""[ \t]*<link\b[^>]*fonts\.(?:googleapis|gstatic)\.com[^>]*"""
    r"""\brel\s*=\s*["']?preconnect["']?[^>]*>[ \t]*\r?\n?""", re.I)
# Google's css2 output: "/* latin */\n@font-face { ... }"
FACE_RE = re.compile(r"/\*\s*([\w\- ]+?)\s*\*/\s*(@font-face\s*\{.*?\})", re.S)
URL_RE = re.compile(r"url\(\s*(['\"]?)(https?://[^)'\"]+)\1\s*\)")


def note(msg):
    print("  - " + msg)


def _ssl_context():
    """Default context; use certifi's CA bundle when it is installed (python.org builds on macOS ship without CAs)."""
    import ssl
    try:
        import certifi  # optional, not standard library
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT, context=_ssl_context()) as resp:
            return resp.read()
    except (urllib.error.URLError, OSError) as exc:
        # Fall back to the system curl (uses the OS certificate store; present on macOS, Linux, Windows 10+).
        curl = shutil.which("curl")
        if not curl:
            raise
        try:
            r = subprocess.run([curl, "-fsSL", "--max-time", str(TIMEOUT), "-A", UA, url],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT + 5)
        except (OSError, subprocess.SubprocessError):
            raise exc
        if r.returncode != 0 or not r.stdout:
            raise exc
        return r.stdout


# ---------------------------------------------------------------- 1. fonts
def embed_fonts(html):
    """Return (new_html, message). Never raises on network problems."""
    m = LINK_RE.search(html)
    if not m:
        if "fonts.googleapis.com" not in html:
            return html, "fonts: already self-contained (no Google Fonts link)"
        return html, "fonts: no <link data-embed-fonts> found, left as is"
    tag = m.group(0)
    hm = HREF_RE.search(tag)
    if not hm:
        return html, "fonts: <link data-embed-fonts> has no href, left as is"
    href = hm.group(2).replace("&amp;", "&")
    try:
        css = fetch(href).decode("utf-8", "replace")
        faces = FACE_RE.findall(css)
        if faces:
            blocks = [blk for subset, blk in faces if subset.strip().lower() == "latin"]
        else:  # no subset comments: keep everything
            blocks = re.findall(r"@font-face\s*\{.*?\}", css, re.S)
        if not blocks:
            raise ValueError("no latin @font-face blocks in the stylesheet")
        cache = {}
        total = 0

        def inline(um):
            nonlocal total
            url = um.group(2)
            if url not in cache:
                data = fetch(url)
                total += len(data)
                mime = "font/woff2" if url.split("?")[0].endswith(".woff2") else "font/woff"
                cache[url] = "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii"))
            return "url(%s)" % cache[url]

        blocks = [URL_RE.sub(inline, b) for b in blocks]
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return html, ("fonts: could not download Google Fonts (%s); the report still works "
                      "with its fallback fonts" % exc)
    style = "<style data-embedded-fonts>\n" + "\n".join(blocks) + "\n</style>"
    html = html[:m.start()] + style + html[m.end():]
    html = PRECONNECT_RE.sub("", html)
    html = PRECONNECT_RE2.sub("", html)
    return html, "fonts: embedded %d font faces (%d KB) as data URIs" % (len(blocks), total // 1024)


# ---------------------------------------------------------------- 2. PDF
def print_copy(html):
    """Open every <details> for printing."""
    def opener(m):
        tag = m.group(0)
        if re.search(r"\bopen\b", tag[8:], re.I):
            return tag
        return tag[:-1].rstrip() + " open>"
    return re.sub(r"<details\b[^>]*>", opener, html, flags=re.I)


def chromium_candidates():
    names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
             "microsoft-edge", "microsoft-edge-stable", "brave-browser", "brave", "chrome", "msedge"]
    paths = []
    if sys.platform == "darwin":
        for app, exe in [("Google Chrome", "Google Chrome"), ("Chromium", "Chromium"),
                         ("Microsoft Edge", "Microsoft Edge"), ("Brave Browser", "Brave Browser"),
                         ("Google Chrome Canary", "Google Chrome Canary")]:
            for root in ("/Applications", os.path.expanduser("~/Applications")):
                paths.append(os.path.join(root, app + ".app", "Contents", "MacOS", exe))
    elif os.name == "nt":
        roots = [os.environ.get(k) for k in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA")]
        rel = [r"Google\Chrome\Application\chrome.exe", r"Chromium\Application\chrome.exe",
               r"Microsoft\Edge\Application\msedge.exe",
               r"BraveSoftware\Brave-Browser\Application\brave.exe"]
        for root in filter(None, roots):
            paths += [os.path.join(root, r) for r in rel]
    for n in names:
        p = shutil.which(n)
        if p:
            paths.append(p)
    seen, out = set(), []
    for p in paths:
        if p and p not in seen and os.path.isfile(p):
            seen.add(p)
            out.append(p)
    return out


def ok_pdf(path):
    try:
        with open(path, "rb") as f:
            return os.path.getsize(path) > 0 and f.read(5) == b"%PDF-"
    except OSError:
        return False


def run(cmd, timeout=180, watch=None):
    """Run a renderer. With watch=PDF path, stop early once that PDF is complete
    (headless browsers sometimes keep running after printing)."""
    import time
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        return -1
    end = time.time() + timeout
    last = -1
    while time.time() < end:
        if proc.poll() is not None:
            return proc.returncode
        if watch and ok_pdf(watch):
            cur = os.path.getsize(watch)
            if cur == last:  # size stable for one poll interval
                break
            last = cur
        time.sleep(1)
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    return 0 if (watch and ok_pdf(watch)) else -1


def make_pdf(html_text, html_path, pdf_path):
    tmpdir = tempfile.mkdtemp(prefix="report-print-")
    try:
        tmp_html = os.path.join(tmpdir, html_path.stem + ".print.html")
        with open(tmp_html, "w", encoding="utf-8") as f:
            f.write(print_copy(html_text))
        uri = Path(tmp_html).resolve().as_uri()
        if os.path.exists(pdf_path):
            os.remove(pdf_path)

        for exe in chromium_candidates():
            profile = os.path.join(tmpdir, "profile")
            base = [exe, "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                    "--user-data-dir=" + profile, "--no-pdf-header-footer",
                    "--print-to-pdf=" + str(pdf_path), uri]
            for headless in ("--headless", "--headless=old"):
                run([base[0], headless] + base[1:], timeout=120, watch=str(pdf_path))
                if ok_pdf(pdf_path):
                    return "PDF: made with %s" % Path(exe).name
        wk = shutil.which("wkhtmltopdf")
        if wk:
            run([wk, "--enable-local-file-access", "--print-media-type", "--quiet", tmp_html, str(pdf_path)])
            if ok_pdf(pdf_path):
                return "PDF: made with wkhtmltopdf"
        try:
            import weasyprint  # noqa: F401  (optional, not standard library)
            weasyprint.HTML(filename=tmp_html).write_pdf(str(pdf_path))
            if ok_pdf(pdf_path):
                return "PDF: made with WeasyPrint (Python module)"
        except Exception:
            pass
        wp = shutil.which("weasyprint")
        if wp:
            run([wp, tmp_html, str(pdf_path)])
            if ok_pdf(pdf_path):
                return "PDF: made with WeasyPrint"
        return None
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


# ---------------------------------------------------------------- 3. open
def open_in_browser(path):
    uri = Path(path).resolve().as_uri()
    try:
        if webbrowser.open(uri):
            return True
    except Exception:
        pass
    try:
        if sys.platform == "darwin":
            return subprocess.call(["open", str(path)]) == 0
        if os.name == "nt":
            os.startfile(str(path))  # type: ignore[attr-defined]
            return True
        return subprocess.call(["xdg-open", str(path)]) == 0
    except Exception:
        return False


def size(p):
    n = os.path.getsize(p)
    return "%.1f MB" % (n / 1048576) if n >= 1048576 else "%d KB" % max(1, n // 1024)


def main():
    ap = argparse.ArgumentParser(description="Embed fonts, make a PDF and open the stress-test HTML report.")
    ap.add_argument("--html", required=True, help="the filled-in HTML report")
    ap.add_argument("--pdf", help="PDF output path (default: next to the HTML, .pdf)")
    ap.add_argument("--no-open", action="store_true", help="do not open the HTML in a browser")
    ap.add_argument("--no-embed-fonts", action="store_true", help="leave the Google Fonts link as is")
    a = ap.parse_args()

    html_path = Path(a.html).expanduser().resolve()
    if not html_path.is_file():
        sys.exit("error: HTML report not found: %s" % html_path)
    pdf_path = Path(a.pdf).expanduser().resolve() if a.pdf else html_path.with_suffix(".pdf")
    html = html_path.read_text(encoding="utf-8")
    leftover = re.findall(r"\{\{[A-Z0-9_]+\}\}", html)

    print("Finishing %s" % html_path.name)
    if a.no_embed_fonts:
        note("fonts: skipped (--no-embed-fonts)")
    else:
        new, msg = embed_fonts(html)
        note(msg)
        if new != html:
            html = new
            html_path.write_text(html, encoding="utf-8")

    msg = make_pdf(html, html_path, pdf_path)
    if msg:
        note(msg)
    else:
        pdf_path = None
        note("PDF: skipped, no renderer found (Chrome, Chromium, Edge, Brave, wkhtmltopdf or WeasyPrint). "
             "To get a PDF, open the HTML in a browser and use Print > Save as PDF "
             "(expand the 'All ... scores' sections first), or install Google Chrome and run this again.")

    if a.no_open:
        note("browser: not opened (--no-open)")
    elif open_in_browser(html_path):
        note("browser: opened the HTML report")
    else:
        note("browser: could not open it automatically; open the HTML file yourself")
    if leftover:
        note("warning: %d unfilled placeholder(s) left, e.g. %s" % (len(leftover), ", ".join(sorted(set(leftover))[:5])))

    md = html_path.with_suffix(".md")
    print("\nReport files:")
    print("  Markdown: %s" % (("%s (%s)" % (md, size(md))) if md.is_file() else "(not found next to the HTML: %s)" % md.name))
    print("  HTML:     %s (%s)" % (html_path, size(html_path)))
    print("  PDF:      %s" % (("%s (%s)" % (pdf_path, size(pdf_path))) if pdf_path else "(not made)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
