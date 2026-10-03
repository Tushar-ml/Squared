# Squared

Split anything (home, trips, couples, friends, work, events, or 1:1 with one friend) and earn coins for keeping it square.
iOS app + local backend, grown from the *Roommate Coins (Splitwise Gamification MVP)* PRD.

First run: `make up` creates `backend/.env.dev` (git-ignored) from `backend/.env.example` with fresh local secrets.
UI uses CRED's NeoPOP iOS components (`neopop-ios` 1.0.0: PopButton, PopFloatingButton, PopView, PopSwitch, PopCheckBox, PopRadioButton).

```
backend/      FastAPI + Postgres: core splitting API, reward module, worker, ops console, tests
vendor-mock/  voucher vendor sandbox (switch to fail/timeout with POST :8090/admin/mode)
ios/          SwiftUI app (xcodegen project.yml)
scripts/      api.py (CLI client), sim.sh (headless simulator helpers)
```

## Run locally (OrbStack)

```bash
make up          # db :5433, api :8080, worker, vendor :8090, mailpit :8025
make test        # 96 backend tests (rewards, caps, splits, FX, insights, reports, activation, recurring, budgets, chat, ops)
make reset       # wipe DB and reseed demo data
```

Demo data (dev only): flat **Flat 4B** with Aman `+919000000001`, Priya `+919000000002`, Rahul `+919000000003`.
Ops reviewer: `+919000000099`. Dev OTP is `DEV_OTP` in `backend/.env.dev`.

- Ops console: http://localhost:8080/ops (wallet search, ledger and lots, reverse, freeze, pending queue, held redemptions, config and kill switch, audit log, run jobs)
- Voucher emails: http://localhost:8025 (Mailpit)

## iOS

```bash
make ios                                   # xcodegen generate
open ios/Squared.xcodeproj           # run on an iPhone simulator
```

The simulator reaches the API at `http://localhost:8080`. For a real device, long-press the logo on the sign-in screen and set your Mac's LAN IP.

Pushes: locally there is no APNs. The worker's notification orchestrator (quiet hours, 2/day cap, batching, opt-outs) marks pushes SENT; the app pulls them from `/me/notifications/deliver` every 8 s while open and shows them as local notifications with the same actionable categories (Confirm / Not right, Yes got it / Not yet). Swap in an APNs sender later.

DEBUG-only automation (used for headless screenshots): `scripts/sim.sh launch -RCNoPrompt -RCLoginPhone +919000000001 -RCRoute wallet`.

## Splitting, currencies, insights

- **Splits**: equal, exact amounts, percent or shares (`split_type` + `participants` / `exact` / `percents` / `shares`). The server computes shares with largest-remainder rounding, so they always add up to the paisa; inputs are stored so edits re-run the same split.
- **Currencies**: every group has a currency. An expense can be typed in another currency; it converts at the live rate (open.er-api.com, Frankfurter/ECB fallback, cached hourly, last-known rates if both are down) and that rate is locked on the expense so balances never drift. Coins are INR-only (PRD 8.13). `GET /api/v1/fx/rates?base=INR`, `GET /api/v1/fx/currencies`.
- **Insights**: `GET /api/v1/groups/{id}/insights?month=YYYY-MM` (paid vs share per member, categories, 6-month trend, top expenses) and `GET /api/v1/me/insights?currency=USD` (my share across all groups at live rates).
- **Reports**: `GET /api/v1/groups/{id}/report?month=YYYY-MM` returns a CSV statement (expenses with each person's share and original currency, payments, monthly summary, outstanding balances). The app exports it through the share sheet.

## Everyday features

- **Recurring bills** (FR-16): `POST /groups/{id}/recurring` (monthly day 1-28 or weekly). The worker adds them on the day through the normal expense path and notifies everyone the day before. Groups can save a default split.
- **Simplify debts**: per-group toggle; shows the fewest payments with identical totals.
- **Comments, receipts, search**: comments per expense; bill photos (JPEG/PNG/HEIC/PDF, 6 MB, stored in `backend/uploads/`) with on-device OCR in the app to fill the amount; search by text, category, person, month and amount.
- **Members**: leave or remove only when the person's balance is settled; group currency locks after the first expense.
- **Budgets**: monthly limits per category with alerts at 80% and 100%.
- **Activity feed, flat chat**, monthly **PDF** statement (`?format=pdf`), **recap card** share image (FR-17).
- **App**: tab bar (Flats, Activity, Coins, Account), light/dark/system appearance, Face ID lock, Hindi coin copy and Hindi pushes (FR-18), home-screen widget (App Group snapshot).
- **Ops** (FR-19): bulk reverse and a collusion-ring report (Rings tab in the console).
- **Production adapters**: APNs (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_PATH`, `APNS_TOPIC`) and SMS OTP (`SMS_PROVIDER=msg91|twilio` + keys). Both stay off until configured.

Everyday notifications (C1 recurring, C2 comments, C3 chat, C4 budgets) respect quiet hours and opt-outs but don't count toward the PRD's 2-per-day coin push cap.

## Design notes

- Invariants from PRD 8.1 are enforced in code: rewards run from a transactional outbox (fail-open), the ledger is append-only (DB trigger), every earn has an idempotency key, every number comes from versioned config (`coin_config`), and caps and goals use IST days and ISO weeks.
- Local dev overrides: all Home groups are in TREATMENT and the first-redemption hold is about 1 minute (`backend/app/seed.py`, `DEV_OVERRIDES`). Production defaults follow the PRD (50/50, 48 h).
- Brands in the catalogue are placeholders (PRD Q3).
- Not built: UPI collect requests (needs a payments partner), bank-SMS parsing (iOS doesn't allow reading SMS), Android, real voucher vendor, production deployment.
