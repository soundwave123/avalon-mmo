# T-695: threaded terrain height sampling for WorldView's ground mesh. Building the vale ground
# needs ~230k TerrainField.height() samples (~1.1s on the main thread at login). height() is a PURE
# read of the immutable region tables, so the grid parallelises cleanly: one WorkerThreadPool task
# per grid ROW, each writing its own contiguous slice of a pre-sized PackedFloat32Array held on THIS
# instance. The buffer lives as an Object member (captured by reference, not COW-copied the way a
# local would be), so distinct-index writes from different rows land in the one buffer with no
# realloc and no shared-write hazard, and the caller (WorldView._build_ground) still builds the mesh
# + trimesh and attaches it on the MAIN thread — the ground exists when _ready returns; only the
# sampling moved off main. The `threaded` decision is the CALLER's (WorldView gates it on
# AVALON_THREADED_LOAD + non-headless): height() touches no renderer/RID — pure float math — so
# unlike a threaded GLB load (the T-697 dummy-renderer hazard) the WorkerThreadPool path is itself
# safe headless, which lets a test verify the shared-buffer write directly. The sampled values are
# byte-identical between the threaded and the inline paths by construction.
extends RefCounted

# Row-major height grid scratch: index [iz * xs.size() + ix]. Only ever read back by the caller
# after the worker group has joined (or after the inline loop returns).
var _buf: PackedFloat32Array


# Sample `terrain`.height() over the xs X zs grid. Returns a row-major PackedFloat32Array sized
# xs.size() * zs.size(); heights[iz * xs.size() + ix] == terrain.height(xs[ix], zs[iz]).
func sample(
	terrain, xs: PackedFloat32Array, zs: PackedFloat32Array, threaded: bool
) -> PackedFloat32Array:
	var nx := xs.size()
	_buf = PackedFloat32Array()
	_buf.resize(nx * zs.size())
	if not threaded:
		for iz in range(zs.size()):
			var base := iz * nx
			for ix in range(nx):
				_buf[base + ix] = terrain.height(xs[ix], zs[iz])
	else:
		var sampler := func(iz: int) -> void:
			var base := iz * nx
			for ix in range(nx):
				_buf[base + ix] = terrain.height(xs[ix], zs[iz])
		var group := WorkerThreadPool.add_group_task(sampler, zs.size(), -1, false)
		WorkerThreadPool.wait_for_group_task_completion(group)
	var result := _buf
	_buf = PackedFloat32Array()  # drop the scratch reference; the caller owns the returned buffer
	return result
