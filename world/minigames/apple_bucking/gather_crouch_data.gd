extends Resource
## Validated FK animation data, baked offline for the exact accepted rig/limits.
@export var rig_signature := ""
@export var bone_names: Array[StringName] = []
@export var key_rotations: Array[PackedFloat32Array] = []
@export var max_fit_error := INF
@export var max_orientation_error := INF
