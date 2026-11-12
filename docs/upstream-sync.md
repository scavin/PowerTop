# Upstream synchronization — 2026-11-13

Reviewed original upstream [`kDolphin/PowerTop` v1.4.4](https://github.com/kDolphin/PowerTop/tree/bd25c693be70cef9833f140618b4b28de61e1345), commit `bd25c693`. The intermediate fork `scavin/PowerTop` remains at `496f4b7`.

This integration retains BatteryView's original icon geometry/colors, immediate connection indication, the optional system/input/net battery metric selector, and the local regression fixes for contradictory power readings. Equivalent upstream fixes are implemented in the fork's existing controllers rather than introducing a second menu bar implementation.

| Upstream behavior | Integration |
| --- | --- |
| Signed battery flow and AC supplement | Preserve signed current and telemetry; show `— W` on conflicting directions or impossible balances. Never invent input from a measured zero. |
| Startup/wake, monitor lifetime, unplug handling | Preserve the initial valid sample and weak timer/notification ownership; explicit IOPS connection events override cached adapter details; cancel transition work on sleep/stop. |
| Native popover, outside click, stable menu title and anchor | Add outside click monitors and cleanup, avoid forcing the popover key, skip unchanged labels, and re-anchor after size/position changes. |
| Capacity/temperature fallback | Read main `BatteryData`, then pack data and appropriate bank fallbacks; support both design-cycle keys. |
| Cell topology and telemetry | Detect series/parallel layout from bank/cell IDs. Keep optional voltage/Qmax attached to their bank; do not duplicate group measurements into physical-cell rows. Unknown parallel topology remains unknown. |
| Cell balance | Display series voltage spread and available within-group current spread. These summaries are heuristics, not battery fault diagnoses. |
| Detail layout | Adopt the upstream overview/capacity/live-reading grouping and aligned columns; fix current direction labels and retain unavailable power formatting. |
| Time estimates | Validate system sentinels; otherwise compute from energy and time-smoothed battery flow. AC supplement uses only battery outflow. Burst refreshes do not accelerate smoothing; estimated/conflicting power suppresses the forecast. |
| Charge targets | Respect current macOS limits, running AlDente limits, or an active optimized-charging hold. Do not infer a target from daily history, an old macOS prior-limit value, or inactive AlDente preferences. This reads settings; it does not change charging limits. |
| Manufacture date | Read explicit `ManufactureDate` from the battery/pack; validate the date and reject future dates. Never interpret arbitrary `ManufacturerData` as a date. |
| Historical averages | Read accumulated system load/count separately from instantaneous power. |
| Menu bar automatic mode, cap, warning | Add automatic input/system choice. Keep the existing selectable metrics. Cap and warnings are optional and off by default; capped text uses a bound such as `≥99W` and the tooltip keeps the full value. |
| Labels and controls | Wrap long metric text, align overview bars, use a compatible cell section symbol, report login-item registration errors, and include the version in details. |
| Unavailable optional readings | Hide missing rows and entire empty sections, including capacity, health, cycles, cell measurements, lifetime statistics, and device strings. Rebuild optional readings on each successful refresh so a failed auxiliary read cannot leave old values visible. Preserve measured zero values. |

## Additional fixes confirmed on this Mac

The live registry exposes `AppleSmartBatteryPack.BatteryData.LifetimeData` and `AppleSmartBatteryBank.BatteryData.CellVoltage/Qmax`. The former is not read by upstream v1.4.4. Read pack-level lifetime data as a fallback, including temperature, voltage and controller operating statistics, and normalize valid signed maximum-discharge current to a magnitude. Controller operating statistics are not proof of the computer's purchase date or total macOS usage time.

Upstream's raw `Amperage` detail label was reversed. Keep positive current labeled charging and negative current labeled discharging. Reported as [kDolphin/PowerTop#16](https://github.com/kDolphin/PowerTop/issues/16).

## Validation

All 42 release tests pass. Regression tests cover recorded power-direction conflicts, actual zero versus missing adapter input, first-frame battery level, unplug events with stale adapter data, cell topology/partial measurements, pack lifetime fields, manufacture-date validation, charge targets, supplemental-discharge estimates, smoothing, optional menu display, and native popover resizing. The three popover tests also pass after the final label-wrapping adjustment.

Rendered previews of the popover, full details, and details without optional telemetry were visually checked. Missing rows and empty sections disappear, and the long menu-bar display label wraps without clipping. Both localization files pass `plutil -lint`, and `git diff --check` passes.

The arm64 1.0.16 (build 16) application bundle builds successfully, is ad-hoc signed, and passes `scripts/verify-app.sh`, including the deep/strict signature check. It is built separately from the installed application; the installed copy has not been replaced or restarted.

`PowerTop-1.0.16.dmg` was created successfully and passed image-checksum verification. A read-only mount confirmed the application and Applications shortcut, and the packaged application's deep/strict signature check passed. The verification mount was detached after checking.
