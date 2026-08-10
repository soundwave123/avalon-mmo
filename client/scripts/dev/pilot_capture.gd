class_name PilotCapture
extends RefCounted

# T-075 framebuffer capture, carved out of pilot.gd (which sits at the 1000-line gdlint cap).
#
# Both ops read Viewport.get_texture().get_image(), which is the RENDER TARGET — WINDOW pixels, not
# the content base. Under T-747's canvas_items stretch that is a real distinction and it is the one
# the pilot's whole agent workflow rests on: a coordinate read off a screenshot is in the same space
# the "click" and "pick" ops expect, so it needs no conversion, while the "ui" op's Control rects
# are CONTENT space and do. content_scale rides along in the ack so a caller can tell the two apart
# instead of assuming they coincide (they only do when the window is pinned to the base, e.g. the
# pilot's default AVALON_PILOT_RESOLUTION=1280x720 — which is exactly why the difference is easy to
# miss in testing and shows up only on a real monitor).


static func screenshot(vp: Viewport, path: String) -> Dictionary:
	# Wait one drawn frame so pending UI changes land in the capture.
	await RenderingServer.frame_post_draw
	var img: Image = vp.get_texture().get_image()
	var err := img.save_png(path)
	return {
		"ok": err == OK,
		"path": path,
		"width": img.get_width(),  # WINDOW pixels
		"height": img.get_height(),
		"content_scale": UiViewport.content_scale(vp),
	}


# Capture `frames` drawn frames (every `every`-th) into dir/f_####.png — pilot.py stitches them into
# a GIF/MP4 so live motion (particles, VFX, day/night, weather) is viewable, not just single frames.
static func record(vp: Viewport, frames: int, dir: String, every: int) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(dir)
	# clear any stale frames from a previous recording
	var d := DirAccess.open(dir)
	if d != null:
		for f in d.get_files():
			if f.begins_with("f_") and f.ends_with(".png"):
				d.remove(f)
	var saved := 0
	for i in range(frames):
		await RenderingServer.frame_post_draw
		if i % every == 0:
			var img: Image = vp.get_texture().get_image()
			# downscale before save — a full-res PNG encodes at ~2s/frame here (the bottleneck);
			# a 720-wide frame saves ~10x faster and is plenty for a review clip.
			if img.get_width() > 720:
				img.resize(
					720, int(720.0 * img.get_height() / img.get_width()), Image.INTERPOLATE_BILINEAR
				)
			img.save_png(dir.path_join("f_%04d.png" % saved))
			saved += 1
	return {"ok": true, "dir": dir, "count": saved}
