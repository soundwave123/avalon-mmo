# T-434: pure PvP crowd-control diminishing returns.
# Clock and target state are explicit inputs; no OS time, RNG, or side effects.

extends RefCounted

const DR_RESET_TICKS := 360  # 18 seconds at 20 Hz, counted from the latest CC attempt
const _MULTIPLIERS := [1.0, 0.5, 0.25, 0.0]


class ControlResult:
	var new_state: CombatState
	var duration_ticks: int = 0
	var resisted: bool = false


static func resolve(
	state: CombatState, category: String, base_ticks: int, now: int, pvp_target: bool
) -> ControlResult:
	var out := ControlResult.new()
	out.new_state = state.copy()
	if base_ticks <= 0:
		out.resisted = true
		return out
	if not pvp_target or category == "":
		out.duration_ticks = base_ticks
		return out

	var reset_at := int(state.control_dr_reset_at.get(category, 0))
	var stage := (
		0 if now >= reset_at else clampi(int(state.control_dr_stages.get(category, 0)), 0, 3)
	)
	out.duration_ticks = int(floor(float(base_ticks) * float(_MULTIPLIERS[stage])))
	out.resisted = out.duration_ticks <= 0
	out.new_state.control_dr_stages[category] = mini(stage + 1, 3)
	out.new_state.control_dr_reset_at[category] = now + DR_RESET_TICKS
	return out
