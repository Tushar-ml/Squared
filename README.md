# Squared

Split anything (home, trips, couples, friends, work, events, or 1:1 with one friend) and earn coins for keeping it square.

Everything runs on the device. There is no server, no account and no sign-in: your data is one file on your phone or Mac. Friends sync shared groups phone to phone over Wi-Fi or Bluetooth when they meet.

UI uses CRED's NeoPOP iOS components (`neopop-ios` 1.0.0).

```
ios/       SwiftUI app for iPhone and Mac (xcodegen project.yml)
scripts/   release.sh (builds the DMG and IPA), sim.sh (simulator helpers)
```

## Install

Grab the files from the [latest release](https://github.com/Tushar-ml/Squared/releases/latest).

### Mac: `Squared-<version>.dmg`

1. Open the DMG and drag **Squared** into Applications.
2. The app isn't notarized, so macOS blocks the first launch. Right-click Squared, choose **Open**, then **Open** again. If macOS says the app is damaged, run `xattr -cr /Applications/Squared.app` once.

### iPhone: free Apple ID, from Xcode

Apps installed with a free Apple ID stop opening after 7 days. Plug the phone in and press Run again to renew them; your data stays.

1. Xcode → Settings → Accounts → **+** → Apple ID, then sign in.
2. Run `make ios`, then `open ios/Squared.xcodeproj`.
3. Select the **Squared** target → Signing & Capabilities. Set Team to *Your Name (Personal Team)*. Do the same for **SquaredWidget**.
4. If Xcode says the bundle ID is taken, change `app.squared.ios` in `ios/project.yml` (for example to `app.squared.<yourname>`), run `make ios` again, and repeat step 3.
5. Connect the iPhone and select it as the run destination, then press Run.
6. Turn on Developer Mode on the phone: Settings → Privacy & Security → Developer Mode.
7. Trust your profile on the phone: Settings → General → VPN & Device Management.

The release also has an unsigned `Squared-<version>.ipa`. Sideloadly or AltStore can sign and install it with a free Apple ID without opening Xcode. The same 7-day limit applies.

## Syncing with friends

1. Open the group, tap **Sync**. Your friend opens Sync on their phone too.
2. Tap their name. The first time, they pick which member of the group they are.

After that, either phone can add, edit or delete expenses and payments, and add people. The next sync brings both phones level:

- Edits merge record by record, and the later edit wins.
- Deletes spread to the other phone.
- Syncing twice changes nothing.

Coins stay personal. Synced expenses earn nothing; only bills you log yourself do. Bill photos, recurring rules and budgets stay on the phone that made them.

## Features

- **Splits**: equal, exact, percent or shares, using largest-remainder rounding so shares always add up to the paisa.
- **Simplify debts**: shows the fewest payments needed.
- **Currencies**: each group has its own currency.
  - Foreign amounts convert at the live rate from open.er-api.com, cached for an hour.
  - The rate is locked on the expense.
  - This is the only network call the app makes.
- **Coins**:
  - First bill +50, each bill +5, settling up +20 (the receiver gets +10).
  - A surprise 2x or 3x bonus can land on a settlement.
  - Log 5 bills in a week for +120.
  - Caps: 60 a day, 600 a month.
- **Everyday**:
  - Recurring bills, budgets with alerts, notes, bill photos with on-device OCR, and search.
  - Activity feed, insights, CSV/PDF statements, and a recap card.
  - Remind with a UPI pay link, a home-screen widget, Face ID lock, light/dark mode, and Hindi.
- **Your data**:
  - Settings → Export backup saves a JSON file.
  - Import restores it, for example on a new phone.
  - Erase all data wipes the device.

## Develop

```bash
make ios     # xcodegen generate
make test    # unit tests: splits, coins, backups, reports, sync merges
scripts/release.sh   # dist/Squared-<version>.dmg and .ipa
```

Debug-only launch flags for simulator screenshots: `scripts/sim.sh launch -RCNoPrompt -RCSkipOnboarding Tushar -RCRoute group:1`.

To try sync, run two simulators side by side. Both must be on the same Mac, which counts as the same network.
