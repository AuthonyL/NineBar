# NineBar

[简体中文](README.zh-CN.md)

NineBar is a macOS menu bar app that watches your Shanghai and Shenzhen A-shares and ETFs on 1-minute and 5-minute bars, counts nine-bar sequences (九转), and alerts you when a sequence reaches bar 8 and when bar 9 is confirmed. The interface is available in Chinese and English.

> **Not investment advice.** NineBar only monitors a price condition on your own Mac. It does not trade, place orders, read accounts, cookies or keychain items. Market data comes from Eastmoney web endpoints, which are not an official API and may change, throttle or stop at any time.

## Requirements

- macOS 14 or later
- Swift 6.2 or later, from Xcode or the Command Line Tools (`xcode-select --install`)

The project has been built and tested with the Swift 6.2 Command Line Tools.

## Quick start

```bash
git clone https://github.com/AuthonyL/NineBar.git
cd NineBar
./run.sh
```

Or double-click `NineBar.command` in Finder. The first build takes a few minutes. `./run.sh --install` also copies the app to `/Applications`, which is the better place for it if you turn on launch at login.

NineBar has no Dock icon. On first launch it watches one example, the CSI 300 ETF (510300). To change that, click its icon in the menu bar, choose **Edit watchlist**, and enter one code per line:

```text
600519
159915 创业板ETF
513500
```

A name after the code is optional; missing names are filled in from the next quote. Saving replaces the whole list. Shanghai and Shenzhen A-shares and exchange-traded ETFs are supported; Beijing Stock Exchange stocks, LOFs, convertible bonds and Hong Kong stocks are not.

To receive alerts, open **Settings → Notifications** and click **Request**.

## How sequences are counted

Each bar's close is compared with the close four bars earlier:

- top sequence: `close[t] > close[t-4]`
- bottom sequence: `close[t] < close[t-4]`

An equal close resets the count, and a missing minute breaks the sequence, which then warms up again over four bars after the gap. Only the comparison across four bars matters, not whether a single bar is up or down.

1-minute and 5-minute bars are counted separately. Only completed bars advance the count:

- **bar 8**: the sequence is close to completing
- **candidate 9**: the ninth bar is still open but the live price already meets the condition
- **confirmed 9**: the ninth bar has closed and passed the data checks

The **reference price** is the highest high of bars 1–9 for a top sequence and the lowest low for a bottom sequence. It is not a forecast or an order price.

During continuous trading, both the request time and the end of the latest minute must be within 75 seconds. Stale, empty, missing or malformed data never advances a count or produces a confirmation. Once the market is closed for the day, NineBar switches from 10-second polling to occasional checks.

This is the same counting rule as the setup phase of TD Sequential. TD Sequential is a trademark of its owner; NineBar is not affiliated with or endorsed by them.

## Settings

- Language: follow the system, Simplified Chinese or English. The app name shown in Finder and notification banners always follows the system language.
- Timeframes: 1 minute and/or 5 minutes.
- Notifications at bar 8 and at confirmed bar 9, with an optional sound at bar 9.
- Launch at login. If macOS shows "Needs approval", approve NineBar in **System Settings → General → Login Items**.
- Local data: storage size and clearing history older than 30 trading days.
- Diagnostics: copies the version, data status, symbol count, timeframes and error categories. It never includes paths, URLs, accounts or raw responses.

History records each confirmed bar 9 with its reference price and the return 5, 15, 30 and 60 minutes later. `—` means the later bars do not exist yet, not a zero return.

## Data and privacy

Everything NineBar stores stays in your user folder:

```text
~/Library/Application Support/NineBar/
├── NineBar.sqlite      bars, signals and notification de-duplication
├── settings.json
├── watchlist.json
└── logs/               time, component, error category and optional symbol only
```

After each normal trading day, bars and signals older than the most recent 30 trading days are removed. Clearing history never touches your settings or watchlist.

## Health check

The app bundle includes a command-line check that fetches `600519` (Shanghai stock) and `159915` (Shenzhen ETF) through the same client and parser as the app:

```bash
dist/NineBar.app/Contents/MacOS/NineBarHealthCheck
```

It prints one line of JSON and exits with 0 only when `ok` is true:

```json
{"errors":[],"latestAgeSeconds":12,"marketOpen":true,"minuteSeriesCount":2,"ok":true,"quoteCount":2}
```

| Field | Meaning |
| --- | --- |
| `ok` | Quotes, names, OHLC values, minute series, a shared trading day and timing all passed for both symbols |
| `marketOpen` | Whether the Shanghai market was in continuous trading at the time |
| `quoteCount`, `minuteSeriesCount` | How many symbols passed, normally 2 |
| `latestAgeSeconds` | Age of the oldest required timestamp, or `null` |
| `errors` | Fixed error categories, never URLs, names, paths or response bodies |

A failure usually means the data source was unavailable at that moment. It says nothing about the counting logic, storage or interface, which the test suite covers.

## FAQ

- **"NineBar can't be opened because Apple cannot check it for malicious software."** This only happens with a copy downloaded from someone else, since locally built apps are signed ad hoc. Build it yourself with `./run.sh`, or right-click the app and choose **Open**.
- **No alerts.** Allow notifications in **System Settings → Notifications → NineBar**, then check the status in NineBar's settings.
- **Data paused or source unavailable.** Check your network and system clock. NineBar first falls back from Eastmoney's minute-history host to its delayed host; if both fail, it pauses rather than confirm signals on old data.

## Development

```bash
scripts/test.sh                      # all tests plus an app bundle check
scripts/test.sh RadarPipelineTests   # tests whose name matches a filter
scripts/build-app.sh release         # build dist/NineBar.app
```

The test targets are executables that use Swift Testing, so they run on hosts that only have the Command Line Tools. Run them through `scripts/test.sh` rather than `swift test`.

```text
Sources/
├── NineBarCore/          domain models, counting engine, market data, storage, notifications
├── NineBarUI/            SwiftUI views and the view model
├── NineBar/              app entry point and wiring
└── NineBarHealthCheck/   command-line data source check
Tests/
├── NineBarCoreTests/
└── NineBarUITests/
Resources/                Info.plist, icons and localized app names
scripts/                  build, test and bundle checks
```

User-facing text is written as Chinese/English pairs with `L10n.t("中文", "English")`, so every string has both languages and the language can change while the app runs.

Automated tests cover the counting rules, aggregation, storage and restart de-duplication on fixed data. The checks that still need a live trading session are listed in [docs/manual-acceptance.md](docs/manual-acceptance.md).

## License

[MIT](LICENSE)
