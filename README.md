# RS_Gestures

Motion-controller gesture recognition for VR. RS_Gestures watches the
controllers and tells a mod what the hands are doing, so an action can hang off
a movement instead of off a button.

A gesture is not one thing, and the three kinds below need different machinery.
Lumping them together is why a drawn-shape recogniser looks like the answer to
all of them and is the answer to one.

| Kind | What it is | Where | Fires |
|---|---|---|---|
| **SHAPE** | a path drawn in the air -- a circle, a cross, a sweep | `rsg_match.zs` | `rsg_matched` |
| **POSE / IMPULSE** | what ONE hand is doing right now -- open, closed, still, thrusting along its own axis | `rsg_signals.zs` | `rsg_thrust` |
| **BOTH HANDS** | a relationship between the two hands -- swept down together, thrown apart, both palms out | `rsg_pair.zs` | `rsg_pair` |

- `rsg_capture.zs` is the per-hand ring buffer the shape matcher normalises
  from: a few seconds of hand pose with the head pose stored alongside every
  sample, which is what lets a shape match the same whichever way the player is
  facing.
- `rsg_record.zs` records your own shapes into four slots, from a menu.
- `rsg_demo_actions.zs` is a small set of example bindings showing how to wire
  one up.

Every detector is **off by default behind its own cvar** (`rsg_enabled`,
`rsg_signals`, `rsg_twohand`) and none of them writes any engine state. The
per-hand and both-hands queries are static, so a mod can ask what a hand is
doing without switching any handler on or loading a recogniser it has no use
for.

## What the events say, and what they do not

All three carry the same shape -- an index and a magnitude in hundredths -- so a
consumer wires a new kind up the way it already wires the last one.

| Event | arg0 | arg1 (hundredths) |
|---|---|---|
| `rsg_matched` | which template | confidence |
| `rsg_thrust` | which hand | speed along that hand's own axis, m/s |
| `rsg_pair` | 0 both hands down, 1 both hands apart, 2 both palms out | the slower hand's downward speed (m/s), how fast the hands are coming apart (m/s), or how long both palms have been out (seconds) |

**None of them carries a claim about what the gesture means, or any geometry.**
The hands are local hardware and the event is seen by every machine, so a
consumer that needs to know which way the hands threw reads the hands on the
machine that has them and sends its own event. Three mods may read the same
`rsg_pair` differently, and that is the point.

## Two things the both-hands detector gets right on purpose

**"Together" is in real milliseconds, and it is measured between the two
movements.** `rsg_two_window_ms` is the dial. Each hand's stamp is when its
fastest instant actually happened (`HandPeakAgeMs` answers that), not the tic it
was noticed on -- otherwise the peak ring's own quarter second of lag would have
to be inside the tolerance, and the window would be wide enough to accept two
deliberately separate sweeps. Real seconds and not map tics, because slowing the
world would otherwise shrink the tolerance by whatever the time scale is.

**Hips and chest are measured from the headset, and in metres.** Against world Z
a gesture would be different for a tall player, unreachable for a short one and
impossible seated. In map units it would be about a fifth off vertically, since
the map's vertical is scaled differently from its horizontals -- and these
gestures are mostly vertical, which is the worst case for that mistake.

## Building

`build.ps1` packs the folder into `RS_GESTURES.pk3`. It needs the UZDXREMA
engine fork for the raw controller reads (`Level.HandPos`,
`Level.HandVelAtPoint`, `HandPeakAgeMs`, the per-hand grip and touch fields).
The build is a well-formedness check -- includes resolve, handlers exist, names
do not collide -- and **not** a ZScript compile; only a real engine load is
that.
