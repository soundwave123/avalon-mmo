class_name CraftingUi
extends RefCounted

# T-414 (slice 3): one mount seam for the crafting client UI so client/main.gd (AT the gdlint file
# cap) grows by a single call — the SocialUi/AchievementUi factory idiom. Builds the RecipePanel
# under the HUD and the GatherNodesLayer in the world, and wires each to the shared transport, the
# chat-typing gate, and the routed-reply hub (each self-registers its own reply types — no per-type
# main.gd handler). The returned instance is discardable: the Nodes live in the tree and the router
# holds Callables into them (mirrors how observe_probe/reply_router were extracted at the cap).


static func mount(
	hud: Node, world: Node, send_fn: Callable, is_typing_fn: Callable, reply_router, combat_log
) -> void:
	var panel := RecipePanel.new()
	panel.name = "RecipePanel"
	hud.add_child(panel)
	panel.setup(send_fn, is_typing_fn, reply_router, combat_log)
	var layer := GatherNodesLayer.new()
	layer.name = "GatherNodes"
	world.add_child(layer)
	layer.setup(send_fn, reply_router)
