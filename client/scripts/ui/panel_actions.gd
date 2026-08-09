class_name PanelActions
extends RefCounted

# T-056 pass 2: routes a panel action meta ("action|arg|...") to the matching ClientNet intent.
# The quest-log + inventory panels emit these via RichTextLabel [url] links (meta_clicked); the
# client sends INTENTS only (the server validates state). Pure dispatch on an injected net, so it's
# unit-tested with a spy.


static func dispatch(net, meta: String) -> void:
	if net == null:
		return
	var p := meta.split("|")
	match p[0]:
		"turn_in":
			if p.size() >= 2:
				net.turn_in(p[1])
		"abandon":
			if p.size() >= 2:
				net.abandon(p[1])
		"equip":
			if p.size() >= 2:
				net.equip(int(p[1]))
		"unequip":
			if p.size() >= 2:
				net.unequip(p[1])
		"drop":
			if p.size() >= 4:
				net.drop(p[1], int(p[2]), int(p[3]))
		"spend_talent":  # T-065: talent UI click — server validates the spend
			if p.size() >= 2:
				net.spend_talent(p[1])
		"reroll_talents":  # T-508: respec confirm — server wipes the build wholesale
			net._reroll_talents()
		"set_class":  # T-065: class selection — server locks after the first set
			if p.size() >= 2:
				net.set_class(p[1])
		"set_gender":  # T-520: gender selection at creation — server locks; shown before class
			if p.size() >= 2:
				net.set_gender(p[1])
		"set_name":  # T-716: the name step at creation — server validates + renames; after class
			if p.size() >= 2:
				net._set_character_name(p[1])
