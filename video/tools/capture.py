"""Capture still frames for the video: architecture diagrams and the live n8n editor.

usage: python -I video/tools/capture.py   (run from the repo root, stack running)
Writes PNGs to video/build/frames/. Reads the local n8n demo owner from .env.
"""
import os
import pathlib
import sys
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / "video" / "build" / "frames"
CHROME = os.environ.get("CHROME_PATH") or next(
    (p for p in (r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                 r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
     if pathlib.Path(p).exists()), None)  # None = Playwright's bundled Chromium
VIEWPORT = {"width": 1920, "height": 940}
N8N = "http://127.0.0.1:5678"
WORKFLOW_ID = "crmLeadSync00001"

BADGE_JS = """
const b = document.createElement('div');
b.textContent = 'Rendered from a real run  ·  Narration: ElevenLabs';
Object.assign(b.style, {position:'fixed', right:'28px', bottom:'24px', zIndex:99999,
  background:'#0f172a', color:'#e2e8f0', font:'600 18px Segoe UI, sans-serif',
  padding:'10px 16px', borderRadius:'10px', boxShadow:'0 6px 20px rgba(0,0,0,.25)'});
document.body.appendChild(b);
"""


def read_env():
    env = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def diagram(page, name):
    url = (ROOT / "docs" / "architecture" / name).as_uri()
    page.goto(url)
    page.wait_for_load_state("networkidle")
    time.sleep(1.5)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    env = read_env()
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=CHROME, headless=True)
        page = browser.new_page(viewport=VIEWPORT, device_scale_factor=1)

        diagram(page, "1-system-architecture.html")
        page.screenshot(path=OUT / "arch_system.png")
        page.evaluate(BADGE_JS)
        page.screenshot(path=OUT / "intro.png")

        diagram(page, "1-system-architecture.html")
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        time.sleep(0.8)
        page.screenshot(path=OUT / "arch_cards.png")

        diagram(page, "2-sync-run-workflow.html")
        page.screenshot(path=OUT / "arch_run.png")
        diagram(page, "3-database-schema.html")
        page.screenshot(path=OUT / "arch_schema.png")

        # n8n editor (local demo owner)
        page.goto(f"{N8N}/signin", wait_until="domcontentloaded")
        page.get_by_label("Email").wait_for(timeout=60000)
        page.get_by_label("Email").fill(env["N8N_DEMO_OWNER_EMAIL"])
        page.get_by_label("Password").fill(env["N8N_DEMO_OWNER_PASSWORD"])
        page.get_by_role("button", name="Sign in").click()
        page.wait_for_url(lambda u: "/signin" not in u, timeout=60000)
        time.sleep(2)

        page.goto(f"{N8N}/workflow/{WORKFLOW_ID}", wait_until="domcontentloaded")
        time.sleep(6)
        page.keyboard.press("Escape")
        page.mouse.click(960, 600)
        page.keyboard.press("Shift+1")  # zoom to fit
        time.sleep(1.5)
        page.screenshot(path=OUT / "n8n_workflow.png")

        page.goto(f"{N8N}/workflow/{WORKFLOW_ID}/executions", wait_until="domcontentloaded")
        time.sleep(6)
        # n8n opens a "Production Checklist" popover here; close it by toggling its badge.
        checklist = page.get_by_text("Production Checklist")
        if checklist.count() and checklist.first.is_visible():
            page.mouse.click(1611, 32)
            time.sleep(1)
        page.screenshot(path=OUT / "n8n_executions.png")

        browser.close()
    print("frames:", sorted(f.name for f in OUT.glob("*.png")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
