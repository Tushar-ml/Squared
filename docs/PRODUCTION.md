# Squared: production launch plan

Status: Phase 1 code done 4 Oct 2026 (redemption off). Remaining Phase 1 items need decisions or accounts. Owner: Tushar. Target: India-first iOS launch (INR, en + hi).

The app works end to end locally (FastAPI + Postgres + worker, iOS app + widget, 100 backend
tests, iOS unit tests). This plan covers what is still missing to run it for real users, in the
order it should happen.

---

## 0. Decisions to make first

These block later phases. Each has a recommended default.

| # | Decision | Options | Recommendation |
|---|----------|---------|----------------|
| D1 | **Who publishes on the App Store** | Individual Apple Developer account (your legal name shows as seller) vs. organization account (needs a registered business + D-U-N-S number) | Individual for the beta and v1; move to an org account later if the app grows (Apple supports transferring an app between accounts). |
| D2 | **Do coins redeem for real vouchers at launch?** | (a) Coins + redemption live, funded by you; (b) coins live, redemption "coming soon"; (c) launch with coins hidden | **(b).** Real voucher providers need a business entity, a funded balance and a contract, and every coin becomes a real liability (4 coins = INR 1). Launch the earning loop, measure it, switch redemption on later via remote config. |
| D3 | **Hosting** | Managed PaaS (e.g. Render, Railway, Fly.io) vs. AWS Mumbai (App Runner/ECS + RDS) | A managed PaaS with a web service, a background worker and managed Postgres with daily backups: the fewest moving parts for one person. Re-evaluate AWS Mumbai once there's real traffic. |
| D4 | **Domain** | Any domain you control | Needed for the API (`api.<domain>`), invite links (`<domain>/j/<token>`), Universal Links, privacy policy and support pages. Buy it before Phase 1. |
| D5 | **SMS provider for OTP** | MSG91, Twilio, others | An Indian provider such as MSG91. Indian SMS needs **DLT registration** (sender ID + approved OTP template) with a telecom operator; this usually requires an entity and takes days to weeks. Start it early. |

---

## 1. Code changes before any real user (about 1–2 weeks)

**Redemption is off** (`coin_config.redemption.enabled = false`): the server refuses redeems with
"coming soon", the app shows the catalogue as a dimmed preview, and no "redeem your coins" push goes out.
Turn it on later with one remote-config publish.

**Still open in Phase 1** (need you): review the legal drafts and set `SUPPORT_EMAIL`; buy the domain and
set `SQUARED_API_BASE_URL` / `SQUARED_LINK_DOMAIN` for Release in `ios/project.yml` (Release builds fail
until you do); create the S3/R2 bucket; DLT registration and the SMS template; APNs key; Sentry; app icon
and screenshots.

### App Store blockers
- [x] **In-app account deletion.** Required by App Store Review Guideline 5.1.1(v). Add `DELETE /me`
      (anonymise the user, keep the ledger and expense integrity, remove PII and devices) and a
      "Delete account" flow in Account settings with confirmation.
- [x] **Privacy policy, terms and support URLs** (drafts at `/legal/terms`, `/legal/privacy`, `/support`; **still need your review**) hosted on the domain; linked from the app and App
      Store Connect. Terms must explain coins: no cash value, non-transferable, can expire, can be
      changed or withdrawn.
- [ ] **App Privacy "nutrition label"** answers in App Store Connect (phone number, name, UPI ID,
      expenses, photos of bills, analytics events, device token).
- [x] **Rewards disclosure.** The random "surprise" coin bonus is chance-based. Show the rules in
      the app, make clear nothing is bought, and state that Apple is not a sponsor (Guideline 5.3).

### Security
- [x] **OTP abuse limits.** Today `/auth/otp/request` has no rate limit, so anyone can trigger SMS
      at your cost, and `/auth/otp/verify` allows unlimited guesses at a 6-digit code. Add: per-phone
      and per-IP send limits with cooldown, max 5 verify attempts per code, short expiry (already
      10 min), and store the code hashed.
- [x] **Turn dev behaviour off by configuration.** `APP_ENV=prod` must mean: no `DEV_OTP`, no demo
      seed, no `dev_hint` in responses. Add a startup check that refuses to boot in prod with a dev
      OTP set or empty secrets.
- [ ] **Ops console.** `/ops` and `/admin/*` are guarded by an `OPS` role. Keep that, add an audit
      check that no OPS user exists by default, and consider serving ops only on a separate
      hostname or behind an IP allowlist.
- [ ] **Secrets** (`SURPRISE_SECRET`, `INVITE_SECRET`, `VOUCHER_KEY`, APNs key, SMS key) live only
      in the host's secret store, never in the repo. Generate new values for prod.

### Infrastructure-facing code
- [x] **Bill photos to object storage.** Uploads are written to `backend/uploads/` on local disk,
      which disappears on most PaaS deploys. Move to S3-compatible storage (S3 or Cloudflare R2)
      with private objects and short-lived signed URLs.
- [x] **Real push** (code side). Already in place: the APNs adapter (`push.py`, token-based `.p8` auth) and the
      app registering for remote notifications and sending its token to `/me/devices`. Left to do:
      configure the APNs key in prod, use the production APNs host (`APNS_SANDBOX=0`) for App Store
      builds, and limit the local-dev pull loop (`/me/notifications/deliver`) to DEBUG builds so
      users don't get duplicates.
- [ ] **Real SMS.** `sms.py` supports MSG91/Twilio; wire the DLT-approved template ID.
- [ ] **Email for vouchers** (only if D2 = a): replace Mailpit with a transactional email service.
- [ ] **Voucher vendor** (only if D2 = a): replace the mock vendor with the chosen provider's API.

### iOS release configuration
- [x] Release build points `RCAPIBaseURL` at `https://api.<domain>`; Debug keeps `localhost`.
      (Today it is hard-coded to `http://localhost:8080` for all builds.)
- [x] Remove `NSAllowsLocalNetworking` from Release.
- [x] **Universal Links** for invites (code side; needs the domain and `APPLE_TEAM_ID`): Associated Domains entitlement `applinks:<domain>` plus an
      `apple-app-site-association` file served by the API, so `https://<domain>/j/<token>` opens the
      app directly instead of bouncing through `squared://`.
- [ ] App icon set, launch screen and App Store screenshots (6.9" and 6.5" iPhone), in light and
      dark.
- [ ] Crash and error reporting (e.g. Sentry) in the app and the API.
- [x] Confirm all automation hooks (`-RCLoginPhone`, `-RCRoute`) stay behind `#if DEBUG`.

---

## 2. Infrastructure (in parallel with Phase 1, about 1 week)

- [ ] Two environments, **staging** and **prod**, each with: API service, worker service, managed
      Postgres 16, object storage bucket, secrets.
- [ ] Migrations run once per deploy, before the new API starts (the runner in `db.py` already
      applies `migrations/*.sql` in order and records them).
- [ ] Postgres: daily automated backups plus point-in-time recovery if the plan allows. **Do one
      restore drill** into staging before launch.
- [ ] TLS on `api.<domain>`; HSTS.
- [ ] Uptime check on `/health`; alert on 5xx rate, worker lag (outbox rows older than 1 minute) and
      failed pushes or SMS.
- [ ] Apple: App ID `app.squared.ios`, widget `app.squared.ios.widget`, App Group
      `group.app.squared.ios`, APNs auth key (`.p8`), Associated Domains capability.

### CI/CD (GitHub Actions)
- [ ] On every push: backend tests against a Postgres service container; `xcodebuild test` on a
      macOS runner.
- [ ] On merge to `main`: deploy to staging automatically; promote to prod by hand.
- [ ] iOS builds: archive and upload to TestFlight from Xcode at first; automate (Xcode Cloud or
      fastlane) once releases are frequent.

---

## 3. Private beta on TestFlight (2–3 weeks)

- [ ] Internal testing (you + a few devices), then an external group of 20–50 people in real flats,
      trips and friend pairs. External TestFlight needs a short Beta App Review.
- [ ] Run against **prod** infra with redemption off (D2).
- [ ] Watch the PRD's numbers: activation (first expense confirmed by someone else within 48h),
      confirmation rate, settle-up time, notification opt-outs, coin earn rate per user.
- [ ] Use the ops console's ring report and the daily/monthly coin caps to catch farming, now that
      any two people (including 1:1 friends) can earn by confirming each other. Decide whether 1:1
      friend pairs should earn less before public launch.
- [ ] Fix what the beta finds; keep the kill switch (`coin_config.kill_switch`) ready.

---

## 4. App Store launch

- [ ] App Store Connect listing: name **Squared**, subtitle, description, keywords, category
      (Finance), age rating, privacy label, support and privacy URLs, review notes with a demo
      account and a test phone number/OTP for the reviewer.
- [ ] Submit; plan for at least one rejection round (rewards wording and account deletion are the
      likely questions).
- [ ] Release with **phased release** (gradual rollout over 7 days) so a bad build can be paused.
- [ ] Hindi App Store listing alongside English.

---

## 5. After launch

- [ ] Weekly metrics review against the PRD goals; adjust earn rates through remote config, not
      app releases.
- [ ] Track coin liability (outstanding coins × INR 0.25) before turning redemption on.
- [ ] Monthly restore test of backups; rotate secrets if anyone else gets access.
- [ ] Grievance/contact address published, as required by India's DPDP Act 2023 for apps handling
      personal data.

---

## Fixed costs to expect

- Apple Developer Program: USD 99 per year.
- Domain: one yearly fee.
- Hosting, Postgres, storage, error tracking: most providers have free or entry tiers that cover a
  beta; budget a small monthly amount for prod Postgres with backups.
- SMS: pay per OTP sent; the rate limits in Phase 1 keep this bounded.
- Vouchers (only if D2 = a): real money per redemption, funded in advance with the provider.
