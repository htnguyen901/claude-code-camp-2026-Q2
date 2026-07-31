# Floating Artifacts

A **floating artifact** is state or behavior that a step depends on but that
doesn't live inside any single step's folder — so it isn't part of what a
`git log`/diff on a step shows, isn't rebuilt by `gem install`, and is easy
for a step rewrite to silently break or drop without anyone noticing until
someone hits it at runtime.

`~/.boukensharc` is the running example: it lives in the user's home
directory, decides which step's *source* the `boukensha` executable
actually runs, and every step from 9 onward depends on it behaving
consistently — but nothing about editing a step's code touches it, and
nothing about `gem install` touches it either. Twice now a step rewrite (or
just normal day-to-day use) has produced a confusing symptom whose root
cause was this file, not the code someone was actually looking at.

## Why this gets its own directory

`docs/plans/<topic>/` (see `../mud_manager/`) is for a specific
feature/subsystem's exploration and design. A floating artifact isn't a
feature — it's a piece of environment/config a step *relies on already
existing correctly*, independent of which step you're currently working in.
Filing it under one specific step's plans would bury it exactly where the
next rewrite (of a *different* step) wouldn't think to look.

## What belongs here

Something that:

- lives outside every step's own folder (a dotfile in `$HOME`, an installed
  gem, an environment variable, a resource shared across steps), **and**
- more than one step depends on behaving a particular way, **and**
- has already caused (or could easily cause) a rewrite to silently regress
  it, or a user to silently run against the wrong version of it.

Each entry should say: what the artifact is, why it's easy to get wrong,
what already went wrong (if anything), and what to check before touching
whatever code manages it next.

## Entries

- [`bounkensharc.md`](bounkensharc.md) — `~/.boukensharc`: resolves which
  step's source the `boukensha` executable runs and where its config lives.
