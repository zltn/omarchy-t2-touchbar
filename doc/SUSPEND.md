# Suspend, and why the sleep hook is deliberately dull

Omarchy removes `tiny-dfr` on T2 Macs. Migration `1785944594.sh` runs
`omarchy-pkg-drop tiny-dfr` on any machine matching `106b:180[12]`, with the
comment that *"the optional daemon holds stale device descriptors across suspend
with t2bce"*. That is a real problem, and anyone reinstalling `tiny-dfr` inherits
it. This is what this repo does about it.

## What did not work

The obvious fix is to re-enumerate the Touch Bar across the sleep boundary:
unload `appletbdrm`, bounce `bConfigurationValue` 0 → 2 on resume, reload. It
works, when the machine comes back.

On 2026-08-16 that hook hard-locked this machine twice on resume within an hour.
The second crash's log ends at `PM: suspend entry (s2idle)` — no suspend exit,
no post hook, nothing. Neither crash left a panic or a pstore record, so nothing
is *proven*. But that hook was the one thing touching USB on `t2bce_vhci`, the
same CRAP-tainted staging bridge the internal keyboard sits on, across suspend —
and suspend interaction with `t2bce` is exactly why Omarchy drops the package.

That variant is kept here as `doc/tiny-dfr-suspend-aggressive.reference` so the
reasoning is not lost, but it is **not** what `install.sh` installs. Do not swap
it in without understanding the above.

## What ships

`tiny-dfr-suspend` stops the daemon before sleep, starts it after, and touches
nothing else. No module unload. No USB re-enumeration.

The trade-off is accepted openly: **the Touch Bar may come back blank**, because
`appletbdrm` keeps descriptors that no longer match after resume — precisely the
"stale device descriptors" Omarchy cited. That is cosmetic and recoverable:

```bash
sudo systemctl restart tiny-dfr
```

which is passwordless via `/etc/sudoers.d/50-tiny-dfr`, and is what the bar
widget's click does. A blank strip is a fair price for a machine that resumes.

## The directory matters

The hook installs to `/usr/lib/systemd/system-sleep/`, **not**
`/etc/systemd/system-sleep/`. systemd 261 compiles in a single hook directory
and ignores the `/etc` one without a word of complaint. A hook in `/etc` is not
an error you can see; it is silence after a completed suspend.

## Checking it actually ran

```bash
journalctl -b 0 -t tiny-dfr-suspend
```

A good cycle logs `pre` → `post` → `done`. **Silence after a completed suspend
means it never ran** — check which directory it is in first.

Cross-check that suspend itself behaved:

```bash
journalctl -b 0 | grep "PM: suspend"
```

Two entry/exit pairs seconds apart means an aborted suspend, which is a
different problem.

## The appletbdrm error baseline

Every config rewrite makes `tiny-dfr` force a complete redraw, which asks
`appletbdrm` for one damage rect covering the whole 2170x60 panel. The driver
allocates that ~509KB transfer buffer with `kvzalloc`; at order-7 contiguity,
under fragmentation `kvzalloc` falls back to `vmalloc`, which the kernel refuses
to DMA:

```
rejecting DMA map of vmalloc memory  ->  Failed to send message (-11)
```

The frame is dropped. Partial redraws are small enough never to hit it, which is
why icon-state changes are coalesced into a single rewrite rather than applied
one at a time.

To measure whether that batching helps, count on a **fresh boot** — service
restarts and test toggles pollute the number:

```bash
journalctl -k -b 0 | grep -c 'Failed to send message'
```

Take the reading before any lid-close, then again after resume.
