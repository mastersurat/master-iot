# cyd-brief

Daily XAUUSD morning brief for the CYD (ESP32-2432S028) "Gold Brief" app.

- `brief.json` – latest brief, read by the board from
  `https://raw.githubusercontent.com/mastersurat/master-iot/cyd-brief/brief.json`
- `brief.md` – same brief in Thai for reading on a phone
- `history/YYYY-MM-DD.json|md` – archive; each day's brief reviews the previous day's plans

Scenario analysis from public sources. Not financial advice.

## Android app (`app/`)
- `app/index.html` – the app's screen. The installed app downloads this on launch (and hourly), so UI changes need no reinstall.
- `app/version.json` + `app/GoldBrief.apk` – when the native part changes, raise `apk_version`; the app shows a download banner.
- The morning-brief task must leave `app/` untouched.

## Plan revisions and lessons
- An intraday check (13:47 and 19:47 Bangkok, weekdays) rewrites `brief.json` only when the plan clearly broke.
  Revisions add `"rev": n` and `"rev_note"`, and are archived as `history/<date>-r<n>.json|md`.
- Order ids: revision 0 uses `<date>-<plan>`; revision n uses `<date>-R<n><plan>` so the EA never mixes them.
- Orders placed on an older revision are never touched automatically; the app flags them with a cancel button.
- `lessons.md` - the morning review logs why a plan missed and the rule that changes the next plans.

## Board firmware (`firmware/`)
- Mini OS 1.3+ checks `firmware/version.json` 1 minute after boot and every 6 hours; if `version` is newer it downloads its build (`builds.<variant>`) and reboots.
- To ship an update: build, copy each `firmware.bin` to `firmware/minios-<variant>-ota.bin`, then raise `version`.
