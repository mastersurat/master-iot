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
