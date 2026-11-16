"""Mock CRM API (Zoho/Bigin-style) with a chaos switch and a chat-style alert sink.

Fictional data only. Standard library only, so the image needs no pip install.

Endpoints
  GET  /crm/v2/Leads?modified_since=ISO&page=1&per_page=200   (headers: Authorization, X-CRM-Org)
  POST /admin/simulate   {"org": "...", "new": 10, "updates": 5, "poison": 0}
  POST /admin/chaos      {"mode": "http_500|rate_limit|timeout|off", "count": 3}
  GET  /admin/manifest?org=...      -> "id|modified_epoch" lines, sorted (for reconciliation)
  POST /hooks/alert      {"text": "..."}   (stands in for a Slack / Google Chat incoming webhook)
  GET  /hooks/alerts     -> alerts received so far
  GET  /health
"""
import json
import os
import random
import sqlite3
import threading
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = os.environ.get("CRM_DB_PATH", "/data/crm.sqlite3")
API_TOKEN = os.environ["CRM_API_TOKEN"]
PORT = int(os.environ.get("PORT", "8080"))
GST = timezone(timedelta(hours=4))  # UAE time, like a Zoho account set to Asia/Dubai
MAX_PER_PAGE = 200
TIMEOUT_SLEEP_SECONDS = 35

ORGS = {
    "org_palmcrest": {"seed": 120, "rng": 7},
    "org_bluedune": {"seed": 90, "rng": 11},
}
FIRST = ["Ahmed", "Fatima", "Omar", "Mariam", "Khalid", "Aisha", "Yousef", "Noura", "Hassan", "Layla",
         "James", "Sarah", "Rahul", "Priya", "Elena", "Mohammed", "Huda", "Tariq", "Sofia", "Daniel"]
LAST = ["Al Mansoori", "Al Hashemi", "Khan", "Haddad", "Al Ali", "Smith", "Nair", "Ivanova",
        "Al Suwaidi", "Rahman", "Farouk", "Al Nuaimi", "Costa", "Mehta", "Al Dhaheri"]
COMMUNITIES = ["Saadiyat Island", "Al Reem Island", "Yas Island", "Al Raha Beach", "Khalifa City",
               "Masdar City", "Al Reef", "Corniche"]
SOURCES = ["Property Finder", "Bayut", "Website", "WhatsApp", "Walk-in", "Referral"]
STAGES = ["New", "Contacted", "Viewing Scheduled", "Negotiation", "Won", "Lost"]
AGENTS = ["Rania (Agent)", "Karim (Agent)", "Joseph (Agent)", "Salma (Agent)"]

_chaos = {"mode": "off", "count": 0, "org": None}
_chaos_lock = threading.Lock()
_db_lock = threading.Lock()


def iso(dt):
    return dt.astimezone(GST).isoformat(timespec="seconds")


def connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def fake_lead(rng, org, n, modified):
    first, last = rng.choice(FIRST), rng.choice(LAST)
    return {
        "org": org,
        "id": f"{org[4:8].upper()}{n:06d}",
        "full_name": f"{first} {last}",
        "mobile": f"+9715{rng.randint(0, 8)}{rng.randint(1000000, 9999999)}",
        "email": f"{first.lower()}.{last.split()[-1].lower()}{n}@example.com",
        "source": rng.choice(SOURCES),
        "stage": rng.choice(STAGES[:4]),
        "owner": rng.choice(AGENTS),
        "budget": rng.randrange(800_000, 6_000_000, 50_000),
        "community": rng.choice(COMMUNITIES),
        "modified_time": iso(modified),
        "modified_epoch": int(modified.timestamp()),
    }


def insert_lead(conn, lead):
    conn.execute(
        """insert into leads (org, id, full_name, mobile, email, source, stage, owner, budget,
                              community, modified_time, modified_epoch)
           values (:org, :id, :full_name, :mobile, :email, :source, :stage, :owner, :budget,
                   :community, :modified_time, :modified_epoch)""",
        lead,
    )


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with _db_lock, connect() as conn:
        conn.execute(
            """create table if not exists leads (
                 org text not null, id text not null, full_name text, mobile text, email text,
                 source text, stage text, owner text, budget integer, community text,
                 modified_time text not null, modified_epoch integer not null,
                 primary key (org, id))"""
        )
        conn.execute("create table if not exists seq (org text primary key, n integer not null)")
        conn.execute("create table if not exists alerts (id integer primary key, at text, body text)")
        for org, cfg in ORGS.items():
            if conn.execute("select 1 from seq where org = ?", (org,)).fetchone():
                continue
            rng = random.Random(cfg["rng"])
            start = datetime.now(GST) - timedelta(days=30)
            for n in range(1, cfg["seed"] + 1):
                modified = start + timedelta(minutes=n * 300 + rng.randint(0, 200))
                insert_lead(conn, fake_lead(rng, org, n, modified))
            conn.execute("insert into seq (org, n) values (?, ?)", (org, cfg["seed"]))


def simulate(org, new, updates, poison):
    if org not in ORGS:
        raise ValueError(f"unknown org {org}")
    now = datetime.now(GST)
    rng = random.Random()
    with _db_lock, connect() as conn:
        # Updates first, so they only ever touch leads that existed before this call.
        rows = conn.execute(
            """select id, stage from leads
                where org = ? and full_name is not null and modified_epoch < ?
                order by random() limit ?""",
            (org, int(now.timestamp()), updates),
        ).fetchall()
        for row in rows:
            nxt = STAGES[min(STAGES.index(row["stage"]) + 1, len(STAGES) - 1)] if row["stage"] in STAGES else "Contacted"
            conn.execute(
                "update leads set stage = ?, modified_time = ?, modified_epoch = ? where org = ? and id = ?",
                (nxt, iso(now), int(now.timestamp()), org, row["id"]),
            )
        n = conn.execute("select n from seq where org = ?", (org,)).fetchone()["n"]
        for _ in range(new):
            n += 1
            insert_lead(conn, fake_lead(rng, org, n, now))
        for _ in range(poison):
            n += 1
            bad = fake_lead(rng, org, n, now)
            bad["full_name"] = None
            bad["mobile"] = "call me after 6"
            insert_lead(conn, bad)
        conn.execute("update seq set n = ? where org = ?", (n, org))
    return {"org": org, "created": new, "updated": len(rows), "poison": poison, "at": iso(now)}


def take_chaos(org):
    """Consume one injected failure if one is armed for this org (or for every org)."""
    with _chaos_lock:
        if _chaos["mode"] == "off" or _chaos["count"] <= 0:
            return None
        if _chaos["org"] not in (None, org):
            return None
        _chaos["count"] -= 1
        mode = _chaos["mode"]
        if _chaos["count"] == 0:
            _chaos["mode"] = "off"
        return mode


def to_api(row):
    return {
        "id": row["id"],
        "Full_Name": row["full_name"],
        "Mobile": row["mobile"],
        "Email": row["email"],
        "Lead_Source": row["source"],
        "Stage": row["stage"],
        "Owner": {"name": row["owner"]},
        "Budget": row["budget"],
        "Community": row["community"],
        "Modified_Time": row["modified_time"],
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "MockCRM/1.0"

    def log_message(self, fmt, *args):
        print(f"[mock-crm] {self.command} {self.path} -> {fmt % args}", flush=True)

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_text(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length == 0:
            return {}
        try:
            body = json.loads(self.rfile.read(length))
        except json.JSONDecodeError as exc:
            raise ValueError(f"invalid JSON body: {exc}") from exc
        if not isinstance(body, dict):
            raise ValueError("JSON body must be an object")
        return body

    def do_GET(self):
        url = urlparse(self.path)
        qs = {k: v[0] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/health":
                return self.send_json(200, {"status": "ok"})
            if url.path == "/crm/v2/Leads":
                return self.list_leads(qs)
            if url.path == "/admin/manifest":
                return self.manifest(qs)
            if url.path == "/hooks/alerts":
                with connect() as conn:
                    rows = conn.execute("select at, body from alerts order by id").fetchall()
                return self.send_json(200, [{"at": r["at"], **json.loads(r["body"])} for r in rows])
            return self.send_json(404, {"code": "NOT_FOUND"})
        except ValueError as exc:
            return self.send_json(400, {"code": "INVALID_DATA", "message": str(exc)})

    def do_POST(self):
        url = urlparse(self.path)
        try:
            body = self.read_json()
            if url.path == "/admin/simulate":
                result = simulate(
                    str(body.get("org", "")),
                    int(body.get("new", 0)),
                    int(body.get("updates", 0)),
                    int(body.get("poison", 0)),
                )
                return self.send_json(200, result)
            if url.path == "/admin/chaos":
                mode = str(body.get("mode", "off"))
                if mode not in ("off", "http_500", "rate_limit", "timeout"):
                    raise ValueError(f"unknown chaos mode {mode}")
                org = body.get("org")
                if org is not None and org not in ORGS:
                    raise ValueError(f"unknown org {org}")
                with _chaos_lock:
                    _chaos.update(mode=mode, count=int(body.get("count", 1)) if mode != "off" else 0,
                                  org=org if mode != "off" else None)
                    return self.send_json(200, dict(_chaos))
            if url.path == "/hooks/alert":
                at = iso(datetime.now(GST))
                with _db_lock, connect() as conn:
                    conn.execute("insert into alerts (at, body) values (?, ?)", (at, json.dumps(body)))
                print(f"\n[ALERT -> #ops-alerts] {body.get('text', body)}\n", flush=True)
                return self.send_json(200, {"ok": True})
            return self.send_json(404, {"code": "NOT_FOUND"})
        except ValueError as exc:
            return self.send_json(400, {"code": "INVALID_DATA", "message": str(exc)})

    def list_leads(self, qs):
        if self.headers.get("Authorization") != f"Zoho-oauthtoken {API_TOKEN}":
            return self.send_json(401, {"code": "INVALID_TOKEN", "message": "invalid oauth token"})
        org = self.headers.get("X-CRM-Org", "")
        if org not in ORGS:
            return self.send_json(403, {"code": "NO_PERMISSION", "message": "unknown organization"})

        chaos = take_chaos(org)
        if chaos == "http_500":
            return self.send_json(500, {"code": "INTERNAL_ERROR", "message": "upstream CRM error"})
        if chaos == "rate_limit":
            return self.send_json(429, {"code": "TOO_MANY_REQUESTS", "message": "API limit exceeded"})
        if chaos == "timeout":
            time.sleep(TIMEOUT_SLEEP_SECONDS)

        since_raw = qs.get("modified_since", "1970-01-01T00:00:00Z")
        try:
            since = int(datetime.fromisoformat(since_raw.replace("Z", "+00:00")).timestamp())
        except ValueError as exc:
            raise ValueError(f"modified_since must be ISO-8601, got {since_raw!r}") from exc
        page = max(int(qs.get("page", "1")), 1)
        per_page = min(max(int(qs.get("per_page", "200")), 1), MAX_PER_PAGE)

        with connect() as conn:
            rows = conn.execute(
                """select * from leads where org = ? and modified_epoch >= ?
                   order by modified_epoch, id limit ? offset ?""",
                (org, since, per_page + 1, (page - 1) * per_page),
            ).fetchall()
        more = len(rows) > per_page
        data = [to_api(r) for r in rows[:per_page]]
        return self.send_json(200, {
            "data": data,
            "info": {"page": page, "per_page": per_page, "count": len(data), "more_records": more},
        })

    def manifest(self, qs):
        org = qs.get("org", "")
        if org not in ORGS:
            raise ValueError(f"unknown org {org}")
        with connect() as conn:
            rows = conn.execute(
                "select id, modified_epoch from leads where org = ? order by id", (org,)
            ).fetchall()
        return self.send_text(200, "".join(f"{r['id']}|{r['modified_epoch']}\n" for r in rows))


if __name__ == "__main__":
    init_db()
    print(f"[mock-crm] listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
