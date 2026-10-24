# Periodic idle wakeups after closing a popover on macOS 27

A small accessory (menu bar) app that shows some content once, closes it, and
then stays idle. A System Trace of the idle process shows whether it keeps
waking up.

Starting point: in a larger app, an `NSPanel` whose content is Liquid Glass
(`NSGlassEffectView`, or SwiftUI `.glassEffect`) kept waking two libdispatch
worker threads about every 3.0 s after the panel had been shown once and
closed with `orderOut`. This repository tries to reproduce that with nothing
else in the process.

**Result in short:** the `NSPanel` + glass case did **not** reproduce here.
An `NSPopover` shown from the status item **does** produce a steady ~3.0 s
wakeup after it is closed, with or without `.glassEffect` in its content, and
the timer keeps running after the popover, its view controller and its view
have been deallocated.

Tested on macOS 27.0.1 (build 26A434), arm64, Swift 6.4 (`swiftc -O`).

## Build and run

```sh
swiftc -O main.swift -o glass-wakeups
./measure.sh popover-plain          # one mode
./measure-all.sh                    # every mode twice, prints a table
```

`measure.sh <mode> [flags]` starts `./glass-wakeups --mode <mode> --auto`,
which shows the content 3 s after launch and closes it 3 s later (no UI
scripting, no accessibility permission). Five seconds after the app prints
`done`, it records a 14 s `System Trace` attached to the pid, exports the
`thread-state` table, takes the start of every `Running` interval of the
process, groups starts within 50 ms into one wake, and prints the wake
times, the intervals and a verdict:

- `periodic ~Xs`: at least 3 wakes are followed by another wake X s later
  (within 3 %), so unrelated extra wakes do not hide a timer;
- `quiet`: at most one wake (the trace attach itself usually causes one);
- `irregular`: anything else.

`top` is not reliable for this: it can report 0 idle wakeups while the trace
shows them.

## Modes

| mode | what is shown |
|------|---------------|
| `never-open` | control: nothing is ever shown (same timing as the others) |
| `no-content` | the `NSPanel`, empty |
| `plain` | the panel with a SwiftUI view (a `Text` and a `Button`), no glass |
| `appkit-glass` | the panel, content view = `NSGlassEffectView` wrapping the hosting view |
| `swiftui-glass` | the panel, SwiftUI `.glassEffect(.regular, in: .rect(cornerRadius: 12))` |
| `appkit-glass-clear` | as `appkit-glass`, `style = .clear` |
| `appkit-glass-container` | `NSGlassEffectContainerView` around the glass view |
| `swiftui-glass-container` | SwiftUI `GlassEffectContainer` around `.glassEffect` |
| `visual-effect` | `NSVisualEffectView` (`.popover` material) instead of glass |
| `popover-glass` | `NSPopover` from the status item, SwiftUI content with `.glassEffect` |
| `popover-plain` | `NSPopover` from the status item, SwiftUI content without `.glassEffect` |
| `popover-teardown` | as `popover-glass`; after closing, `contentViewController = nil`, the popover is released, and weak references prove that popover, controller and view are deallocated |
| `control-timer` | positive control: the app's own 3 s `DispatchSourceTimer`, nothing shown |

Flags (with any mode): `--twice` (a second show/close cycle 3 s after the
first; with `popover-teardown` the popover is recreated from scratch),
`--click` (show through the status item button's `performClick`),
`--activate` (activate the app first), `--borderless` (borderless,
transparent panel at status bar level), `--below-item` (panel right below the
status item), `--under-mouse` (panel under the cursor).

## Results

Each case was run twice with `./measure-all.sh` on an idle machine (no
interaction during the runs).

| case | run 1 | run 2 |
|------|-------|-------|
| never-open | quiet | quiet |
| no-content | irregular (2 wakes, 7.0 s apart) | quiet |
| plain | quiet | irregular (2 wakes, 5.1 s) |
| appkit-glass | quiet | irregular (2 wakes, 5.5 s) |
| swiftui-glass | quiet | quiet |
| appkit-glass-clear | quiet | irregular (2 wakes, 5.1 s) |
| appkit-glass-container | irregular (2 wakes, 5.1 s) | irregular (2 wakes, 6.2 s) |
| swiftui-glass-container | irregular (3 wakes, 5.5 s, 1.4 s) | quiet |
| visual-effect | quiet | irregular (2 wakes, 5.2 s) |
| **popover-glass** | **periodic ~3.0 s** | **periodic ~3.0 s** |
| **popover-plain** | **periodic ~3.0 s** (3.03 3.00 3.00 3.00) | **periodic ~3.0 s** (3.02 3.00 3.00 3.00) |
| **popover-teardown** (all deallocated) | **periodic ~3.0 s** | **periodic ~3.0 s** |
| popover-glass --twice | periodic ~3.0 s | periodic ~3.0 s |
| popover-teardown --twice (all deallocated, twice) | 3 s grid, one beat 0.2 s early (detector: irregular) | same |
| control-timer | periodic ~3.0 s (3.000 3.001 3.000) | periodic ~3.0 s |
| appkit-glass --twice | irregular (4 wakes, no 3 s pattern) | irregular (8 wakes, no 3 s pattern) |
| appkit-glass --click | quiet | quiet |
| appkit-glass --activate | quiet | irregular (2 wakes, 1.3 s) |
| appkit-glass --borderless | quiet | irregular (3 wakes, 2.8 s, 0.5 s) |
| appkit-glass --below-item | irregular (2 wakes, 2.4 s) | irregular (2 wakes, 8.8 s) |
| appkit-glass --under-mouse | quiet | quiet |
| swiftui-glass --borderless --below-item | quiet | quiet |

Repeats: `appkit-glass --twice` was run two more times and gave 2 wakes 7.5 s
apart both times (quiet in practice). `popover-teardown --twice` was run two
more times and showed the same 3 s grid (for example wakes at 3.27, 6.04,
9.27, 12.27 s): a ~3 s timer with one beat shifted, which the strict detector
labels irregular. An earlier full run, made while the machine was in use,
gave the same picture (popover cases periodic ~3.0 s, panel cases quiet or
irregular), with one popover-glass run labelled irregular because of extra
wakes.

## Where the wake comes from

The `syscall` table of a System Trace of `popover-glass` carries backtraces.
At two of the wakes, 3.0 s apart, the worker threads were running dispatch
timer sources owned by the GPU stack:

- `RB::Device::schedule_collection` → `RB::Device::prune_caches` (RenderBox),
  releasing Metal buffers and heaps;
- `AGX::Device::setupDeferred` → `AGX::Device::purgeDevice` (the GPU driver),
  shrinking a pooled allocator.

The other wakes made no syscall with a backtrace, so not every wake could be
attributed; these two frameworks are the only owners that were seen.

## Interpretation

In this minimal app, a closed `NSPopover` leaves a ~3 s periodic wakeup of
two libdispatch workers, whether or not its SwiftUI content uses
`.glassEffect`, and the wakeup continues after the popover, its controller
and its view are verifiably deallocated, so it is not caused by the app
retaining them. The backtraces point at GPU resource cache collection in
system frameworks, which suggests a system issue tied to the popover's
rendering (on macOS 27 the popover background itself is a glass material);
this was not proven, and no other macOS version was tested.

What was not reproduced: an `NSPanel` with `NSGlassEffectView` or
`.glassEffect` content stayed quiet or showed a couple of unrelated wakes in
every variation tried here (container views, clear style, borderless,
positioned at the status item or under the cursor, shown through the status
item button, activated, shown twice). The ~3 s timer seen with such a panel in
a larger app therefore needs something not present here.

Workaround observed: the modes that do not use a popover (and so do not keep
the popover's glass background) stay quiet after closing. Releasing the
popover does not help.
