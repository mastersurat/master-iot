# Order queue for GoldBriefBridge (MT5 EA)

- `req-<date>-<plan>.json` – written by the Gold Brief app when you tap "Follow plan"
- `cancel-<date>-<plan>.json` – written by the app when you tap Cancel
- `status-<date>-<plan>.json` – written by the EA: PLACED / REJECTED / CANCELLED / FILLED / EXPIRED / CLOSED

One request per plan per day. Requests expire at 06:30 Bangkok the next day.
