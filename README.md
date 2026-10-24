# Periodic idle wakeups after closing glass UI with a text field on macOS 27

This is a small accessory (menu bar) app. It shows a panel or popover once, closes it, and then sits idle. A System Trace of the idle process shows whether it keeps waking up.

**Result in short.** The process keeps waking about every 3.0 s after the UI has closed in two cases:

- an `NSPanel` holding the Liquid Glass material (`NSGlassEffectView` or SwiftUI `.glassEffect`) **together with a SwiftUI `TextField`**, after it has been shown once and closed with `orderOut`;
- an `NSPopover` shown from the status item. Its content can be plain SwiftUI, SwiftUI with `.glassEffect`, or plain SwiftUI with a `TextField`: all three were measured, and all three wake.

Without the glass, the text field causes no periodic wake. Without the text field, the glass panel causes none either.

The script measures only when the process runs. The following details come from reading the traces by hand: each wake runs two libdispatch worker threads for a few microseconds. "Keeps waking" means the wakes continued for the whole trace: 20 s in the table below, and 60 s in one longer run (see Results).

Tested on macOS 27.0.1 (build 26A434), arm64, Swift 6.4 (`swiftc -O`). No other macOS version was tested.

## Build and run

```sh
swiftc -O main.swift -o glass-wakeups
./measure.sh appkit-glass --text-field   # one case
./measure-all.sh                         # every case twice, then a table
```

`measure.sh <mode> [flags]` does the following:

1. It starts `./glass-wakeups --mode <mode> --auto`. The app shows the UI 3 s after launch and closes it 3 s later, so no UI scripting or accessibility permission is needed.
2. Five seconds after the app prints `done`, it records a 20 s `System Trace` attached to the app's pid. Set `TRACE_SECONDS` to change the length.
3. It exports the `thread-state` table and takes the start of every `Running` interval of the process. Starts within 50 ms of each other count as one wake.
4. It prints the wake times, the intervals and a verdict.

The verdicts are:

- `periodic ~Xs`: there is a chain of at least 4 wakes, each 0.85 to 1.15 times X after the previous one. Extra unrelated wakes do not break the chain. The timer's leeway is tolerated: its first beats land a few hundred ms early or late, as in 2.8, 3.2, 3.0, 3.0 s.
- `quiet`: at most two wakes. Attaching the trace causes one wake near the start (about 5 s in), and stopping it causes one near the end (about 19 s in).
- `irregular`: anything else.

`top` is not reliable for this. It can report 0 idle wakeups while the trace shows them.

## Modes and flags

| mode | content |
|------|---------|
| `never-open` | control: nothing is ever shown, with the same timing as the other modes |
| `no-content` | an empty `NSPanel` |
| `plain` | the panel with a SwiftUI view (a `Text` and a `Button`), no glass |
| `appkit-glass` | the panel; its content view is an `NSGlassEffectView` wrapping the hosting view |
| `swiftui-glass` | the panel with `.glassEffect(.regular, in: .rect(cornerRadius: 12))`, no AppKit glass view |
| `appkit-glass-clear` | as `appkit-glass`, with `style = .clear` |
| `appkit-glass-container` | an `NSGlassEffectContainerView` around the glass view |
| `swiftui-glass-container` | a SwiftUI `GlassEffectContainer` around `.glassEffect` |
| `visual-effect` | an `NSVisualEffectView` (`.popover` material) instead of glass |
| `popover-glass` | an `NSPopover` from the status item; its SwiftUI content uses `.glassEffect` |
| `popover-plain` | the same popover; its content has no `.glassEffect` and no text field |
| `popover-teardown` | as `popover-glass`; after closing, the app sets `contentViewController = nil` and releases the popover. Weak references then show that the popover, its controller and its view were deallocated. |
| `control-timer` | positive control: the app's own 3 s `DispatchSourceTimer`, with nothing shown |

These flags work with any mode:

| flag | effect |
|------|--------|
| `--text-field` | adds a SwiftUI `TextField` to the content |
| `--resign` | clears the panel's first responder before closing |
| `--orderfront` | shows the panel with `orderFront` instead of `makeKeyAndOrderFront` |
| `--twice` | runs a second show/close cycle 3 s after the first; with `popover-teardown`, the second popover is built from scratch |
| `--click` | shows the UI through the status item button's `performClick` |
| `--activate` | activates the app first |
| `--borderless` | makes the panel borderless, transparent and at status bar level |
| `--below-item` | places the panel right below the status item |
| `--under-mouse` | places the panel under the cursor |

## Results

Every case was run twice with `./measure-all.sh` on an idle machine. Times are in seconds from the start of the trace.

| case | run 1 | run 2 |
|------|-------|-------|
| never-open | quiet | quiet |
| no-content | quiet | quiet |
| plain | quiet | quiet |
| appkit-glass | quiet | quiet |
| swiftui-glass | irregular (3 wakes) | quiet |
| appkit-glass-clear | irregular (3 wakes) | irregular (4 wakes) |
| appkit-glass-container | quiet | irregular (5 wakes) |
| swiftui-glass-container | irregular (3 wakes) | irregular (3 wakes) |
| visual-effect | quiet | quiet |
| plain --text-field | quiet | quiet |
| visual-effect --text-field | periodic ~3.7 (4 of 9 wakes, see below) | quiet |
| **appkit-glass --text-field** | **periodic ~3.0** (1.23 4.06 7.27 10.27 13.26 16.23 19.03) | **periodic ~3.0** (6 of 12 wakes) |
| **swiftui-glass --text-field** | **periodic ~3.0** (7 of 7 wakes) | **periodic ~3.0** (4 of 8 wakes) |
| **appkit-glass --text-field --resign** | **periodic ~3.0** | **periodic ~3.0** |
| **appkit-glass --text-field --orderfront** | **periodic ~3.0** | **periodic ~3.0** |
| **popover-glass** | **periodic ~3.0** | **periodic ~3.0** |
| **popover-plain** | **periodic ~3.0** | **periodic ~3.0** (1.40 4.42 7.43 10.42 13.34 16.42 19.23) |
| **popover-plain --text-field** | **periodic ~3.0** | **periodic ~2.9** |
| **popover-teardown** (everything deallocated) | **periodic ~3.0** | **periodic ~3.0** |
| popover-glass --twice | periodic ~3.0 | periodic ~3.0 |
| popover-teardown --twice (everything deallocated, both times) | periodic ~3.0 | periodic ~3.0 |
| control-timer | periodic ~3.0 (2.67 5.67 8.67 … 20.67) | periodic ~3.0 |
| appkit-glass --twice | irregular (4 wakes) | irregular (8 wakes) |
| appkit-glass --click | quiet | quiet |
| appkit-glass --activate | quiet | quiet |
| appkit-glass --borderless | quiet | quiet |
| appkit-glass --below-item | irregular (3 wakes) | irregular (3 wakes) |

The `irregular` results have a few wakes at random times, with no 3 s pattern.

`visual-effect --text-field` run 1 had 9 scattered wakes, and four of them happened to form a 3.7 s chain. Two more runs gave 13 and 4 scattered wakes, again with no 3 s pattern (wake times in run 2: 3.30, 8.94, 18.78, 19.42). This mode is noisier than the others, but it shows no steady timer.

**Long run.** One 60 s trace of `appkit-glass --text-field` gave 21 wakes, 20 of them on the ~3.0 s chain, from the first second of the trace to the last (58.05 s). It did not die out.

### Finding the text field

The ~3 s wakes were first seen in a larger menu bar app. Its borderless glass panel shows sign-in text fields, toggles, glass buttons, a `TimelineView`, symbol images and more. That app was bisected with the same trace method by removing one group of features at a time. Each step was traced twice, with 14 s traces from an earlier version of the script:

| removed, cumulatively | result |
|------|--------|
| nothing | periodic ~3.0 s |
| glass button styles, `TimelineView`, list rows, dividers, action buttons, secondary text styles, trailing modifiers, header and title texts | periodic ~3.0 s at every step |
| also the toggles; only one `TextField` left | periodic ~3.0 s |
| also that `TextField` | irregular |

Then the starting point was restored, and only its two text fields were removed. That app was quiet in both runs. The window style, level, collection behaviour, shadow and corner masking, the status item's SwiftUI icon and the global event monitor were all present in that quiet run, so none of them is needed. The trivial panel content in this repository reproduces the wakes once a `TextField` is added.

## Where the wake comes from

Some rows of the trace's `syscall` table carry backtraces. Those taken at two consecutive wakes, 3 s apart, point at dispatch timer sources in the GPU stack. This holds for `appkit-glass --text-field` and for `popover-glass`:

- `RB::Device::schedule_collection` → `RB::Device::prune_caches` (RenderBox), which releases Metal buffers and heaps;
- `AGX::Device::setupDeferred` → `AGX::Device::purgeDevice` (the GPU driver), which shrinks a pooled allocator.

The later wakes made no syscall with a backtrace, so they could not be attributed. These two owners are the only ones seen. The trigger is not the first render of just any content. A text field without glass, and glass without a text field, both render and stay quiet.

## Interpretation

The behaviour depends on what has been drawn, and nothing the app keeps alive explains it:

- Releasing a popover, its controller and its view, all verified with weak references, does not stop the timer.
- Clearing the first responder before closing does not stop it.
- Showing the panel without making it key does not stop it.
- The text field does not need automatic keyboard focus. In the larger app, the field was kept but nothing gave it focus (no `@FocusState` assignment); the wakes stayed periodic in both runs. In the repro, `--orderfront` never makes the panel key, so no field has focus, and the wakes remain.

The backtraces point at GPU cache-collection timers in system frameworks. This suggests a system issue that involves the glass material: a panel needs glass plus a text field, and a popover triggers it on its own, possibly because its background is drawn with glass. That last point is an assumption and was not verified. The owning framework was only partly identified, and other text controls (`NSTextField`, `TextEditor`, `SecureField` alone) were not tested.

**Observed workaround:** do not combine the glass material with a text field in the panel. For example, use a panel without `NSGlassEffectView` or `.glassEffect`, or keep text fields out of the glass panel. Avoid `NSPopover` for content that is shown once and then stays closed. Tearing views down on close does not help.
