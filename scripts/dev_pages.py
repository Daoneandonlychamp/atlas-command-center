#!/usr/bin/env python3
"""Serve the ATLAS HTML surfaces in a browser, with live reload.

The pages are built to run inside a WKWebView that hands them data over a
message bridge, under a CSP that blocks the network. Opened straight from disk
in a browser they come up blank: nothing answers the bridge, and `default-src
'none'` refuses the poster and API requests Cinema needs.

This closes both gaps for local work only:

  * the CSP meta tag is rewritten to allow images and API calls,
  * `window.webkit.messageHandlers` is stubbed with fixture data,
  * a poller reloads the tab whenever a served file changes on disk.

Nothing here ships. The bundled pages are untouched; every change is made to the
bytes on their way out, so what the app loads is still the file in the repo.

    python3 scripts/dev_pages.py            # http://localhost:8787
    python3 scripts/dev_pages.py --port 9000

Caveat worth knowing: the mock bridge accepts writes and echoes them back, so
editing a bill or renaming a source works in the browser but is thrown away on
reload. Layout, styling and interaction are what this is for. Anything that has
to persist still needs the real app.
"""

import argparse
import http.server
import json
import os
import re
import socketserver
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Sources" / "AtlasCore" / "Resources"

PAGES = {
    "/cinema": "cinema.html",
    "/finances": "finances.html",
    "/crm": "crm.html",
    "/calendar": "calendar.html",
    "/kanban": "kanban.html",
    "/canvas": "canvas.html",
    "/hud": "hud.html",
    "/chat": "chat.html",
}

# Where the real library was backed up, if it is still around. Falls back to a
# small stub so the server works on any machine.
CINEMA_BACKUP = Path(
    "/private/tmp/claude-501/-Users-dave/3a130e5e-dfca-4864-aaaf-08793c83858c"
    "/scratchpad/cinema-backup"
)


def shared_css() -> str:
    """The same two sheets AtlasSharedStyles injects, in the same order."""
    out = []
    for name in ("atlas-theme.css", "atlas-components.css"):
        path = RESOURCES / name
        if path.exists():
            out.append(path.read_text())
    return "\n".join(out)


def cinema_state() -> dict:
    """Real library data when the backup is present, a stub otherwise."""
    values = {}
    if CINEMA_BACKUP.is_dir():
        for path in CINEMA_BACKUP.glob("atlas_*.json"):
            values[path.stem] = path.read_text()
    if "atlas_cinema_library_v1" not in values:
        values["atlas_cinema_library_v1"] = json.dumps(
            {"version": 1, "favorites": [], "watchLater": [], "playlists": []}
        )
    return {"ok": True, "adopt": False, "values": values}


def finances_state() -> dict:
    """A payload shaped exactly like FinancesBridge.reload() sends."""

    def sub(i, name, amount, cadence, due, days, category, **extra):
        row = {
            "id": f"s{i}", "name": name, "amount": amount,
            "amountText": money(amount), "currency": "usd",
            "cadence": cadence, "cadenceLabel": cadence.title(),
            "nextDueOn": due, "daysUntil": days,
            "category": category, "categoryLabel": category.title(),
            "source": "manual", "notes": "", "isActive": True,
            "monthlyEquivalent": amount, "yearly": amount * 12,
            "dueSoon": 0 <= days <= 14, "editable": True,
        }
        row.update(extra)
        return row

    subs = [
        sub(1, "Vercel", 2000, "monthly", "2026-09-14", 5, "infrastructure"),
        sub(2, "Neon", 1900, "monthly", "2026-09-20", 11, "infrastructure"),
        sub(3, "Railway", 2500, "monthly", "2026-10-01", 22, "infrastructure",
            priceChange={"previous": 2000, "previousText": "$20.00",
                         "delta": 500, "deltaText": "$5.00", "rose": True,
                         "at": "2026-09-01"}),
        sub(4, "Figma", 1500, "monthly", "2026-09-08", -1, "software"),
        sub(5, "Google One", 999, "monthly", "2026-10-10", 31, "personal",
            scheduled={"amount": 1999, "amountText": "$19.99",
                       "from": "2026-10-10", "delta": 1000, "pending": True}),
    ]
    expenses = [
        {"id": "e1", "name": "Domain renewal", "amount": 1200,
         "amountText": "$12.00", "currency": "usd", "category": "services",
         "categoryLabel": "Services", "spentOn": "2026-09-03", "notes": ""},
        {"id": "e2", "name": "Apple Developer", "amount": 9900,
         "amountText": "$99.00", "currency": "usd", "category": "software",
         "categoryLabel": "Software", "spentOn": "2026-09-01", "notes": ""},
    ]
    monthly = sum(s["monthlyEquivalent"] for s in subs)

    return {
        "subscriptions": subs,
        "expenses": expenses,
        "infraOffers": [
            {"name": "fly", "label": "Fly", "detail": "current spend",
             "amountText": "$7.20", "available": True},
        ],
        "canSync": True,
        "summary": {
            "activeSubscriptions": len(subs),
            "monthlyCommitted": monthly, "yearlyCommitted": monthly * 12,
            "dueSoonCount": 3, "dueSoonTotal": 5400,
            "overdueCount": 1, "priceChangeCount": 1,
            "futureMonthly": monthly + 1000, "pendingPriceChangeCount": 1,
        },
        "month": {"label": "September 2026", "subscriptions": monthly,
                  "expenses": 11100, "out": monthly + 11100},
        "options": {
            "cadences": [{"value": c, "label": c.title()} for c in
                         ["weekly", "fortnightly", "monthly", "quarterly",
                          "semiannual", "yearly"]],
            "categories": [{"value": c, "label": c.title()} for c in
                           ["software", "infrastructure", "hardware", "services",
                            "marketing", "office", "personal", "other"]],
            "strategies": [{"value": "avalanche", "label": "Avalanche"},
                           {"value": "snowball", "label": "Snowball"}],
        },
        "plan": {
            "profile": {"openingCash": 420000, "openingCashText": "$4,200.00",
                        "recurringIncome": 600000,
                        "recurringIncomeText": "$6,000.00",
                        "nextIncomeOn": "2026-09-15",
                        "monthlyDebtBudget": 50000,
                        "monthlyDebtBudgetText": "$500.00",
                        "buffer": 100000, "bufferText": "$1,000.00",
                        "isConfigured": True},
            "credit": {
                "totalBalanceText": "$1,240.00", "totalLimitText": "$8,000.00",
                "utilization": "15.5%", "projectedUtilization": "8.0%",
                "plannedPaymentText": "$600.00",
                "toReach30": "—", "toReach10": "$440.00",
                "accounts": [
                    {"id": "a1", "name": "Sapphire",
                     "balanceText": "$820.00", "balanceInput": "820.00",
                     "limit": 500000, "limitText": "$5,000.00",
                     "limitInput": "5000.00", "aprInput": "24.99",
                     "minimumInput": "35.00", "plannedInput": "200.00",
                     "planned": 20000, "plannedText": "$200.00",
                     "paymentDueOn": "2026-10-05", "paymentDueLabel": "Oct 5",
                     "statementClosesOn": "2026-09-12",
                     "statementClosesLabel": "Sep 12",
                     "openedOn": "2024-01-01", "autopayEnabled": True,
                     "isActive": True, "notes": "",
                     "utilization": "16.4%", "projectedUtilization": "12.4%",
                     "toReach30": "—", "toReach10": "$320.00"},
                    {"id": "a2", "name": "Amex",
                     "balanceText": "$420.00", "balanceInput": "420.00",
                     "limit": 300000, "limitText": "$3,000.00",
                     "limitInput": "3000.00", "aprInput": "19.99",
                     "minimumInput": "25.00", "plannedInput": "",
                     "planned": 0, "plannedText": "$0.00",
                     "paymentDueOn": "2026-09-28", "paymentDueLabel": "Sep 28",
                     "statementClosesOn": "2026-09-05",
                     "statementClosesLabel": "Sep 5",
                     "openedOn": "2023-06-01", "autopayEnabled": False,
                     "isActive": True, "notes": "",
                     "utilization": "14.0%", "projectedUtilization": "14.0%",
                     "toReach30": "—", "toReach10": "$120.00"},
                ],
            },
            "forecast": {"income": 600000, "incomeText": "$6,000.00",
                         "out": 13087, "outText": "$130.87",
                         "ending": 586913, "endingText": "$5,869.13",
                         "lowest": -13087, "lowestText": "-$130.87",
                         "lowestOn": "Sep 28", "safeToSpend": 0,
                         "safeToSpendText": "$0.00", "hasShortfall": True},
            "actions": [
                {"id": "forecast-shortfall", "kind": "urgent",
                 "title": "Cover the upcoming cash shortfall",
                 "detail": "Projected balance falls below zero within 30 days.",
                 "impact": "Protects scheduled payments from failing.",
                 "amountText": "$130.87", "deadline": "Sep 28"},
                {"id": "price-rise", "kind": "protect",
                 "title": "Railway raised its price",
                 "detail": "$20.00 to $25.00 with no notice.",
                 "impact": "Adds $60.00 a year.",
                 "amountText": "$5.00"},
                {"id": "autopay", "kind": "improve",
                 "title": "Turn on autopay for Amex",
                 "detail": "A missed minimum costs more than the payment.",
                 "impact": "Removes one way to be late."},
            ],
            "debt": {"strategy": "avalanche", "budgetText": "$500.00",
                     "minimumsText": "$60.00", "budgetCoversMinimums": True,
                     "shortfallText": "$0.00", "payoffMonths": 3,
                     "interestText": "$31.20", "interestSavedText": "$4.80",
                     "allocations": [
                         {"name": "Sapphire", "amountText": "$465.00"},
                         {"name": "Amex", "amountText": "$35.00"}],
                     "hasDebt": True},
        },
        "moneyIn": {
            "configured": True, "isLive": False, "isStale": False,
            "complete": False, "generatedAt": "9 Sep 2026 at 21:00",
            "droppedTextFields": 14,
            "totals": {"netText": "$1,284.00", "grossText": "$1,420.00",
                       "refundedText": "$136.00", "openDisputeText": "$99.00",
                       "chargesSeen": 42, "paidCount": 38, "payoutCount": 3,
                       "disputedCount": 2, "openDisputeCount": 1,
                       "unpaidInvoiceCount": 2, "failedPaymentCount": 1,
                       "activeSubscriptions": 12},
            "unavailable": ["Balance transactions"],
            "infra": {"complete": False, "knownText": "$64.20",
                      "providersCounted": 3, "providerTotal": 4,
                      "providers": [
                          {"name": "Railway", "available": True,
                           "uncapped": True, "plan": "HOBBY",
                           "currentText": "$25.00", "estimatedText": "est $31.00"},
                          {"name": "Vercel", "available": True,
                           "uncapped": False, "plan": "PRO",
                           "currentText": "$20.00"},
                          {"name": "Neon", "available": True, "uncapped": False,
                           "currentText": "$19.20",
                           "note": "Scale plan, usage billed monthly"},
                          {"name": "Fly", "available": False, "uncapped": False,
                           "note": "token not configured"},
                      ]},
        },
        "today": "2026-09-09",
    }


def calendar_state() -> dict:
    """Events and reminders around today, so the dashboard has real shape.

    Dates are generated relative to the day the server runs; a fixture with
    hardcoded dates renders an empty week the moment it goes stale.
    """
    import datetime as dt

    now = dt.datetime.now().replace(minute=0, second=0, microsecond=0)
    midnight = now.replace(hour=0)

    def at(day: int, hour: int, length: int = 1):
        start = midnight + dt.timedelta(days=day, hours=hour)
        return start.isoformat(), (start + dt.timedelta(hours=length)).isoformat()

    def event(eid, title, day, hour, length=1, calendar="Personal", all_day=False,
              location=None):
        start, end = at(day, hour, length)
        return {"id": eid, "title": title, "start": start, "end": end,
                "location": location, "notes": None, "calendar": calendar,
                "color": "#ffffff", "allDay": all_day, "editable": True}

    def due(day: int, hour: int):
        return (midnight + dt.timedelta(days=day, hours=hour)).isoformat()

    return {
        "events": [
            event("e1", "Lunch with Ada", 0, 13, location="Fioretta"),
            event("e2", "Jordan\u2019s birthday", 0, 0, 24, "Family", True),
            event("e3", "Standup", 0, 9, 1, "Work"),
            event("e4", "Rosh Hashanah", 2, 0, 24, "Holidays", True),
            event("e5", "Design review", 3, 15, 2, "Work"),
            event("e6", "Chat GPT Plus \u2014 $21.28", 4, 7, 1, "ATLAS Bills"),
            event("e7", "Dentist", 6, 11),
            event("e8", "Yom Kippur", 11, 0, 24, "Holidays", True),
        ],
        "reminders": [
            {"id": "r1", "title": "Chat GPT Plus \u2014 $21.28", "due": due(4, 7),
             "completed": False, "list": "ATLAS Bills"},
            {"id": "r2", "title": "Claude Code \u2014 $106.60", "due": due(18, 7),
             "completed": False, "list": "ATLAS Bills"},
            {"id": "r3", "title": "railway \u2014 $7.64", "due": due(21, 0),
             "completed": False, "list": "ATLAS Bills"},
            {"id": "r4", "title": "Revoke premium from sam@example.com",
             "due": due(26, 9), "completed": False, "list": "Reminders"},
            {"id": "r5", "title": "Confirmed - Calendly", "due": None,
             "completed": False, "list": "Reminders"},
            {"id": "r6", "title": "Send the invoice", "due": due(-2, 9),
             "completed": False, "list": "Work"},
        ],
        "calendars": [
            {"id": "c1", "title": "Personal"},
            {"id": "c2", "title": "Work"},
            {"id": "c3", "title": "Family"},
        ],
        "canWrite": True,
    }


def money(minor: int) -> str:
    return f"${minor // 100:,}.{abs(minor % 100):02d}"


def dev_shim() -> str:
    """Mock bridge + live reload, injected ahead of each page's own script."""
    return """
(function () {
  var CINEMA = %s;
  var FINANCES = %s;
  var CALENDAR = %s;

  function later(fn) { setTimeout(fn, 30); }

  // Stands in for the WKWebView bridge. Writes are acknowledged and echoed so
  // the interaction completes, but nothing is stored — reloading starts over.
  var handler = {
    postMessage: function (raw) {
      var msg = raw;
      if (typeof raw === 'string') { try { msg = JSON.parse(raw); } catch (e) { msg = {}; } }
      console.log('[dev bridge]', msg);

      if (msg.action === 'range') {
        later(function () {
          window.atlasCalendar && window.atlasCalendar.render(JSON.stringify(CALENDAR));
        });
      } else if (msg.action === 'quickAdd') {
        later(function () {
          window.atlasCalendar && window.atlasCalendar.quickAddResult(
            JSON.stringify({ error: 'Dev server: quick add needs the app' }));
        });
      } else if (window.atlasCalendar && msg.action) {
        later(function () {
          window.atlasCalendar.notify('Dev server: ' + msg.action + ' is a no-op', false);
        });
      } else if (msg.action === 'load') {
        later(function () {
          window.atlasFinances && window.atlasFinances.render(JSON.stringify(FINANCES));
        });
      } else if (msg.action === 'setStrategy') {
        FINANCES.plan.debt.strategy = msg.strategy;
        later(function () {
          window.atlasFinances && window.atlasFinances.render(JSON.stringify(FINANCES));
        });
      } else if (msg.action === 'parseInvoices') {
        later(function () {
          window.atlasFinances && window.atlasFinances.invoices(JSON.stringify({
            candidates: [
              { id: 'c1', description: 'Vercel Pro', amountText: '$20.00',
                date: 'Sep 1', include: true },
              { id: 'c2', description: 'Neon Scale', amountText: '$19.20',
                date: 'Sep 3', include: true, warning: 'date guessed' }
            ]
          }));
        });
      } else if (msg.action && msg.action.indexOf('save') === 0) {
        later(function () {
          window.atlasFinances && window.atlasFinances.saved(
            JSON.stringify({ message: 'Saved (not persisted in dev)' }));
        });
      } else if (msg.action === 'syncCalendar') {
        later(function () {
          window.atlasFinances && window.atlasFinances.note(
            JSON.stringify({ message: 'Dev server: sync is a no-op' }));
        });
      }
    }
  };

  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = { atlas: handler, atlasBridge: handler };

  window.addEventListener('DOMContentLoaded', function () {
    later(function () {
      if (window.atlasCinemaState) {
        window.atlasCinemaState(JSON.stringify(CINEMA));
      }
    });
  });

  // Live reload: ask what changed, reload when it has.
  var stamp = null;
  setInterval(function () {
    fetch('/__stamp').then(function (r) { return r.text(); }).then(function (next) {
      if (stamp === null) { stamp = next; return; }
      if (next !== stamp) { location.reload(); }
    }).catch(function () {});
  }, 700);
})();
""" % (json.dumps(cinema_state()), json.dumps(finances_state()),
       json.dumps(calendar_state()))


def newest_mtime() -> str:
    newest = 0.0
    for path in list(RESOURCES.glob("*.html")) + list(RESOURCES.glob("*.css")):
        newest = max(newest, path.stat().st_mtime)
    return str(newest)


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # The access log drowns out the reload notices.

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path == "/__stamp":
            return self.send_text(newest_mtime(), "text/plain")

        if path == "/":
            links = "".join(
                f'<li><a href="{route}">{name}</a></li>'
                for route, name in sorted(PAGES.items())
            )
            return self.send_text(
                "<meta charset=utf-8><title>ATLAS pages</title>"
                "<style>body{background:#0b0b0f;color:#eee;font:15px/1.7 "
                "-apple-system,sans-serif;padding:40px}a{color:#7cc4ff}"
                "li{margin:4px 0}</style>"
                f"<h2>ATLAS pages</h2><ul>{links}</ul>"
                "<p style='color:#888;font-size:13px;max-width:60ch'>Fixture data, "
                "mock bridge, live reload on save. Writes are acknowledged but "
                "discarded.</p>",
                "text/html",
            )

        if path in PAGES:
            return self.send_page(PAGES[path])

        # Sibling assets a page loads directly (sortable, markdown, fonts).
        asset = RESOURCES / path.lstrip("/")
        if asset.is_file() and asset.parent == RESOURCES:
            kind = ("text/css" if asset.suffix == ".css"
                    else "application/javascript" if asset.suffix == ".js"
                    else "application/octet-stream")
            return self.send_bytes(asset.read_bytes(), kind)

        self.send_error(404)

    def send_page(self, filename: str):
        source = (RESOURCES / filename).read_text()

        # The shipped policy blocks images and the network, which is right in the
        # app and fatal in a browser. Widened here only.
        source = re.sub(
            r'<meta http-equiv="Content-Security-Policy"[^>]*>',
            '<meta http-equiv="Content-Security-Policy" content="'
            "default-src 'none'; style-src 'unsafe-inline'; "
            "script-src 'unsafe-inline'; img-src * data:; "
            "connect-src *; font-src *; frame-src *; media-src *; "
            'form-action \'none\'; base-uri \'none\'">',
            source,
            count=1,
        )

        # Shared sheet first, then the shim, both before the page's own <style>
        # and <script> — the same order AtlasSharedStyles uses.
        injection = (
            "<style id='atlas-shared-styles'>" + shared_css() + "</style>"
            "<script>" + dev_shim() + "</script>"
        )
        if "</head>" in source:
            source = source.replace("</head>", injection + "</head>", 1)
        else:
            source = injection + source

        self.send_bytes(source.encode(), "text/html")

    def send_text(self, body: str, kind: str):
        self.send_bytes(body.encode(), kind)

    def send_bytes(self, body: bytes, kind: str):
        self.send_response(200)
        self.send_header("Content-Type", f"{kind}; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    with Server(("127.0.0.1", args.port), Handler) as httpd:
        print(f"ATLAS pages → http://localhost:{args.port}")
        for route in sorted(PAGES):
            print(f"    http://localhost:{args.port}{route}")
        print("\nEdit a file in Sources/AtlasCore/Resources and the tab reloads.")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
