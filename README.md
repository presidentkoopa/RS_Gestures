# RS_Gestures

Motion-controller gesture recognition for VR. RS_Gestures watches the
controllers, records their paths (`rsg_record.zs`), turns a path into a
comparable shape (`rsg_capture.zs`) and matches it against stored gestures
(`rsg_match.zs`), so a mod can hang an action off a swing, a flick or a drawn
shape instead of off a button. `rsg_demo_actions.zs` is a small set of example
bindings showing how to wire one up.

`build.ps1` packs the folder into `RS_GESTURES.pk3`. It needs the UZDXREMA
engine fork for the raw controller reads.
