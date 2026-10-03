# Roommate Coins

iOS app + local backend for the *Roommate Coins (Splitwise Gamification MVP)* PRD.
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
make test        # 54 backend tests (every AB rule and cap, property, replay, concurrency)
make reset       # wipe DB and reseed demo data
```

Demo data (dev only): flat **Flat 4B** with Aman `+919000000001`, Priya `+919000000002`, Rahul `+919000000003`.
Ops reviewer: `+919000000099`. Dev OTP is `DEV_OTP` in `backend/.env.dev`.

- Ops console: http://localhost:8080/ops (wallet search, ledger and lots, reverse, freeze, pending queue, held redemptions, config and kill switch, audit log, run jobs)
- Voucher emails: http://localhost:8025 (Mailpit)

## iOS

```bash
make ios                                   # xcodegen generate
open ios/RoommateCoins.xcodeproj           # run on an iPhone simulator
```

The simulator reaches the API at `http://localhost:8080`. For a real device, long-press the logo on the sign-in screen and set your Mac's LAN IP.

Pushes: locally there is no APNs. The worker's notification orchestrator (quiet hours, 2/day cap, batching, opt-outs) marks pushes SENT; the app pulls them from `/me/notifications/deliver` every 8 s while open and shows them as local notifications with the same actionable categories (Confirm / Not right, Yes got it / Not yet). Swap in an APNs sender later.

DEBUG-only automation (used for headless screenshots): `scripts/sim.sh launch -RCNoPrompt -RCLoginPhone +919000000001 -RCRoute wallet`.

## Design notes

- Invariants from PRD 8.1 are enforced in code: rewards run from a transactional outbox (fail-open), the ledger is append-only (DB trigger), every earn has an idempotency key, every number comes from versioned config (`coin_config`), and caps and goals use IST days and ISO weeks.
- Local dev overrides: all Home groups are in TREATMENT and the first-redemption hold is about 1 minute (`backend/app/seed.py`, `DEV_OVERRIDES`). Production defaults follow the PRD (50/50, 48 h).
- Brands in the catalogue are placeholders (PRD Q3).
- Not built yet: P1 items FR-16 to FR-19 (recurring bills, recap share card, Hindi, ops bulk tools), real SMS/APNs/vendor integrations, production deployment.
