class_name AutoAttackIndicatorState
extends RefCounted

# T-571 (report #26): re-pressing the auto-attack key (a natural corrective action after
# repositioning) silently CANCELED combat because nothing on screen showed whether auto-attack
# was already on. main.gd owns the `_autoattack` bool; PlayerHud renders whatever this pure
# mapping returns, so the ON/OFF presentation is unit-testable without a live scene tree.

const ON_TEXT := "Auto-Attack: ON"
const OFF_TEXT := "Auto-Attack: OFF"
const ON_COLOR := Color(0.55, 1.0, 0.55)  # bright green glow — unmistakably active
const OFF_COLOR := Color(0.55, 0.55, 0.55)  # dim grey — unmistakably inactive


static func label_text(active: bool) -> String:
	return ON_TEXT if active else OFF_TEXT


static func color(active: bool) -> Color:
	return ON_COLOR if active else OFF_COLOR
