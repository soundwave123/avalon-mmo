class_name AutoAttackIndicatorState
extends RefCounted

# T-571 (report #26): re-pressing the auto-attack key (a natural corrective action after
# repositioning) silently CANCELED combat because nothing on screen showed whether auto-attack
# was already on. main.gd owns the `_autoattack` bool; PlayerHud renders whatever this pure
# mapping returns, so the ON/OFF presentation is unit-testable without a live scene tree.

# T-729: auto-attack became a sticky MODE, so ON now has two honest readings — swinging at a live
# hostile, or armed-and-waiting (no target / a corpse / a friendly). Collapsing both into "ON"
# would re-create the #26 confusion from the other side: the player would see ON and wonder why
# nothing is happening. `engaged` defaults true so every pre-T-729 caller reads unchanged.
const ON_TEXT := "Auto-Attack: ON"
const IDLE_TEXT := "Auto-Attack: ON (idle)"
const OFF_TEXT := "Auto-Attack: OFF"
const ON_COLOR := Color(0.55, 1.0, 0.55)  # bright green glow — unmistakably active
const IDLE_COLOR := Color(0.95, 0.85, 0.45)  # amber — armed, but nothing legal to hit
const OFF_COLOR := Color(0.55, 0.55, 0.55)  # dim grey — unmistakably inactive


static func label_text(active: bool, engaged: bool = true) -> String:
	if not active:
		return OFF_TEXT
	return ON_TEXT if engaged else IDLE_TEXT


static func color(active: bool, engaged: bool = true) -> Color:
	if not active:
		return OFF_COLOR
	return ON_COLOR if engaged else IDLE_COLOR
