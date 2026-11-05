# Changelog

All notable changes to Devin Usage. Versions follow [Semantic Versioning](https://semver.org):
**major** for changes that break how you use the app, **minor** for new features, **patch**
for fixes.

Add changes under **Unreleased** as you make them. `scripts/release.sh` turns that section
into the new version's section, and the release on GitHub uses it as release notes.

## Unreleased

## 1.0.0 - 2026-11-06

Initial release.

- Menu bar item with the daily usage percentage and a choice of icons. Optionally the
  weekly limit too: `13% / 5%`. When usage can't be fetched and the data has gone stale,
  it shows `?`, and the dropdown keeps the last known numbers.
- Dropdown with daily and weekly usage bars, reset times, and an "updated 42s ago"
  counter.
- Usage chart in the dropdown for the current day or week: your usage over time, the
  pace of each stretch of use, and where the current pace leads by the daily reset.
- The dropdown estimates how many full daily limits are left in the weekly limit,
  learned from your own usage history, with a margin of error:
  `≈ 3.4 ± 0.2 of 7.5 ± 0.3 full days left`.
- Reads the Devin sign-in saved by Devin Desktop or the Devin CLI, read-only, and polls
  Devin's usage API on the refresh interval with exponential backoff on rate limits.
- Settings: icon, weekly usage in the menu bar, refresh interval, usage chart, launch
  at login.
- Universal app (Apple silicon and Intel) for macOS 15 and later.
