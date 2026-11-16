"""Turn the captured scenario output (video/build/term/s1..s5.ansi) into one terminal frame per step.

usage: python -I video/tools/render_terminal.py
Writes video/build/frames/<segment>.png and video/build/frames/reveal.json
(the pixel row where each step's output starts, used for the line-by-line reveal).
"""
import html
import json
import os
import pathlib
import re
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
TERM = ROOT / "video" / "build" / "term"
OUT = ROOT / "video" / "build" / "frames"
CHROME = os.environ.get("CHROME_PATH") or next(
    (p for p in (r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                 r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
     if pathlib.Path(p).exists()), None)  # None = Playwright's bundled Chromium
W, H = 1920, 940

SEGMENTS = {
    1: ["11_s1_initial", "12_s1_changes", "13_s1_incremental", "14_s1_bulk", "15_s1_idempotent"],
    2: ["21_s2_blip", "22_s2_new_leads", "23_s2_outage", "24_s2_fails", "25_s2_replay", "26_s2_quarantine"],
    3: ["31_s3_own_rows", "32_s3_filter", "33_s3_update", "34_s3_insert", "35_s3_tokens", "36_s3_worker"],
    4: ["41_s4_backup", "42_s4_drill", "43_s4_business", "44_s4_accident", "45_s4_restore", "46_s4_catchup"],
    5: ["51_s5_version", "52_s5_deploy", "53_s5_breaks", "54_s5_rollback", "55_s5_replay"],
}

ANSI = re.compile(r"\x1b\[([0-9;]*)m")
COLORS = {"31": "#f87171", "32": "#4ade80", "33": "#facc15", "36": "#22d3ee"}

PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;background:#0b1020;}}
.win{{position:absolute;inset:18px 22px 18px 22px;background:#0f172a;border-radius:14px;
  box-shadow:0 20px 50px rgba(0,0,0,.5);overflow:hidden;border:1px solid #1e293b}}
.bar{{height:38px;background:#111827;display:flex;align-items:center;padding:0 16px;gap:8px;
  border-bottom:1px solid #1e293b}}
.dot{{width:12px;height:12px;border-radius:50%}}
.title{{color:#94a3b8;font:500 14px 'Segoe UI',sans-serif;margin-left:14px}}
.body{{padding:18px 26px;transform-origin:0 0}}
pre{{margin:0;font:19px/1.42 'Cascadia Mono','Consolas',monospace;color:#cbd5e1;white-space:pre-wrap;
  word-break:break-word}}
.prompt{{color:#a78bfa}} .b{{font-weight:700}} .d{{opacity:.6}}
.step{{display:block;background:#1e293b;border-left:4px solid #22d3ee;margin:6px 0 10px;padding:4px 10px}}
</style></head><body><div class="win">
<div class="bar"><span class="dot" style="background:#f87171"></span><span class="dot" style="background:#facc15"></span>
<span class="dot" style="background:#4ade80"></span><span class="title">bash · ~/leadflow-ops-demo</span></div>
<div class="body" id="body"><pre>{context}</pre><pre id="out">{output}</pre></div></div></body></html>"""


def ansi_to_html(text):
    out, bold, dim, color = [], False, False, None
    pos = 0
    for m in ANSI.finditer(text):
        out.append(span(text[pos:m.start()], bold, dim, color))
        for code in (m.group(1) or "0").split(";"):
            if code in ("0", ""):
                bold = dim = False
                color = None
            elif code == "1":
                bold = True
            elif code == "2":
                dim = True
            elif code in COLORS:
                color = COLORS[code]
        pos = m.end()
    out.append(span(text[pos:], bold, dim, color))
    return "".join(out)


def span(chunk, bold, dim, color):
    if not chunk:
        return ""
    cls = " ".join(c for c, on in (("b", bold), ("d", dim)) if on)
    style = f' style="color:{color}"' if color else ""
    esc = html.escape(chunk)
    return f'<span class="{cls}"{style}>{esc}</span>' if (cls or style) else esc


def split_steps(raw):
    """Return (banner_lines, [(step_header, body_lines), ...])."""
    lines = raw.replace("\r", "").split("\n")
    banner, steps, current = [], [], None
    for line in lines:
        plain = ANSI.sub("", line)
        if plain.lstrip().startswith("▶"):
            current = (line, [])
            steps.append(current)
        elif current is None:
            if plain.strip():
                banner.append(line)
        else:
            current[1].append(line)
    for _, body in steps:  # trim trailing blank lines
        while body and not ANSI.sub("", body[-1]).strip():
            body.pop()
    return banner, steps


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    reveal = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=CHROME, headless=True)
        page = browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=1)
        for n, names in SEGMENTS.items():
            banner, steps = split_steps((TERM / f"s{n}.ansi").read_text(encoding="utf-8"))
            if len(steps) != len(names):
                print(f"scenario {n}: expected {len(names)} steps, found {len(steps)}", file=sys.stderr)
                return 1
            for name, (header, body) in zip(names, steps):
                context = (f'<span class="prompt">$ ./demo.sh {n}</span>\n'
                           + ansi_to_html("\n".join(banner)) + "\n"
                           + f'<span class="step">{ansi_to_html(ANSI.sub("", header).strip())}</span>')
                page.set_content(PAGE.format(context=context, output=ansi_to_html("\n".join(body))))
                # Scale down long outputs so the whole step fits on screen.
                info = page.evaluate("""() => {
                  const body = document.getElementById('body');
                  const avail = window.innerHeight - 18*2 - 38 - 10;
                  const s = Math.min(1, avail / body.scrollHeight, (window.innerWidth - 44 - 4) / body.scrollWidth);
                  body.style.transform = `scale(${s})`;
                  const out = document.getElementById('out').getBoundingClientRect();
                  return {scale: s, outTop: Math.round(out.top), outBottom: Math.round(out.bottom)};
                }""")
                page.screenshot(path=OUT / f"{name}.png")
                reveal[name] = info
                print(f"{name}: scale {info['scale']:.2f}")
        browser.close()
    (OUT / "reveal.json").write_text(json.dumps(reveal, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
