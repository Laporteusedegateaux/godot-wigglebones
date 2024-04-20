@tool
extends Node3D
enum Axis {
	X_Plus, Y_Plus, Z_Plus, X_Minus, Y_Minus, Z_Minus
}

@export var enabled: bool = true
@export var skeleton: Skeleton3D
@export var bone_name: String:
	set(name):
		bone_name = name
		if skeleton:
			skeleton.clear_bones_global_pose_override()
			var temp_bone_id = skeleton.find_bone(bone_name)
			if temp_bone_id != -1:
				bone_id = temp_bone_id
@export_range(1, 20, 1) var chain_length : int = 1

@export_range(0.1,100,0.1) var stiffness: float = 1
@export_range(0,100,0.1) var damping: float = 0
@export var use_gravity: bool = false
@export var gravity := Vector3(0, -9.81, 0)
@export var forward_axis: Axis = Axis.Z_Minus
@export_node_path("CollisionShape3D") var collision_shape: NodePath 



var bone_id: int
var bone_id_parent: int
var collision_sphere: CollisionShape3D

var previous_length

var prev_pos_dict = {}
var current_pose_dict = {}

func set_collision_shape(path:NodePath) -> void:
	collision_shape = path
	collision_sphere = get_node_or_null(path)
	if collision_sphere:
		assert(collision_sphere is CollisionShape3D and collision_sphere.shape is SphereShape3D, "%s: Only SphereShapes are supported for CollisionShapes" % [ name ])


func _ready() -> void:
	if not enabled:
		set_physics_process(false)
		return
	top_level = true  # Ignore parent Transform3D
	setup_bones()
	set_physics_process(true)
	previous_length = chain_length

func setup_bones():
	skeleton.clear_bones_global_pose_override()
	set_collision_shape(collision_shape)
	
	assert(! (is_nan(position.x) or is_inf(position.x)), "%s: Bone position corrupted" % [ name ])
	assert(bone_name, "%s: Please enter a bone name" % [ name ])
	bone_id = skeleton.find_bone(bone_name)
	assert(bone_id != -1, "%s: Unknown bone %s - Please enter a valid bone name" % [ name, bone_name ])
	bone_id_parent = skeleton.get_bone_parent(bone_id)
	if chain_length > 1 :
			for i in range(bone_id, (bone_id + chain_length)):
				prev_pos_dict[i] = skeleton.global_transform.origin * skeleton.get_bone_global_pose(i).origin
				current_pose_dict[i] = skeleton.global_transform * skeleton.get_bone_global_pose(i)
				print(i, skeleton.get_bone_name(i))
	else:
		prev_pos_dict[bone_id] = skeleton.global_transform.origin * skeleton.get_bone_global_pose(bone_id).origin
		current_pose_dict[bone_id] = skeleton.global_transform * skeleton.get_bone_global_pose(bone_id)
	print(prev_pos_dict)
	

func _physics_process(delta) -> void:
	for current_bone in range(bone_id, bone_id + chain_length):
		handle_bone(current_bone, delta)
	
	check_for_changes()

func handle_bone(current_bone_id, delta):
	# Note:
	# Local space = local to the bone
	# Object space = local to the skeleton (confusingly called "global" in get_bone_global_pose)
	# World space = global

	# See https://godotengine.org/qa/7631/armature-differences-between-bones-custom_pose-Transform3D
	
	var current_bone_id_parent : int = skeleton.get_bone_parent(current_bone_id)
	
	var bone_transf_obj: Transform3D = skeleton.get_bone_global_pose(current_bone_id) # Object space bone pose
	var bone_transf_world: Transform3D = skeleton.global_transform * bone_transf_obj
	
	var bone_transf_rest_local: Transform3D = skeleton.get_bone_rest(current_bone_id)
	var bone_transf_rest_obj: Transform3D = skeleton.get_bone_global_pose(current_bone_id_parent) * bone_transf_rest_local
	var bone_transf_rest_world: Transform3D = skeleton.global_transform * bone_transf_rest_obj
	
	
	############### Integrate velocity (Verlet integration) ##############	
	
	# If not using gravity, apply force in the direction of the bone (so it always wants to point "forward")
	var grav: Vector3
	if use_gravity:
		grav = gravity
	else :
		grav = (bone_transf_rest_world.basis * get_bone_forward_local()).normalized() * 9.81
	
	var vel: Vector3 = (current_pose_dict[current_bone_id].origin - prev_pos_dict[current_bone_id]) / delta
	
	grav *= stiffness
	vel += grav
	vel -= vel * damping * delta  # Damping

	prev_pos_dict[current_bone_id] = current_pose_dict[current_bone_id].origin
	current_pose_dict[current_bone_id].origin += vel * delta

	############### Solve distance constraint ##############

	var goal_pos: Vector3 = skeleton.to_global(skeleton.get_bone_global_pose(current_bone_id).origin)
	current_pose_dict[current_bone_id].origin = goal_pos + (current_pose_dict[current_bone_id].origin - goal_pos).normalized()

	if collision_sphere:
		# If bone is inside the collision sphere, push it out
		var test_vec: Vector3 = current_pose_dict[current_bone_id].origin - collision_sphere.global_transform.origin
		var distance: float = test_vec.length() - collision_sphere.shape.radius
		if distance < 0:
			current_pose_dict[current_bone_id].origin -= test_vec.normalized() * distance

	############## Rotate the bone to point to this object #############

	var diff_vec_local: Vector3 = (bone_transf_world.affine_inverse() * current_pose_dict[current_bone_id].origin).normalized()

	var bone_forward_local: Vector3 = get_bone_forward_local()

	# The axis+angle to rotate on, in local-to-bone space
	var bone_rotate_axis: Vector3 = bone_forward_local.cross(diff_vec_local)
	var bone_rotate_angle: float = acos(bone_forward_local.dot(diff_vec_local))

	if bone_rotate_axis.length() < 1e-3:
		return  # Already aligned, no need to rotate

	bone_rotate_axis = bone_rotate_axis.normalized()

	# Bring the axis to object space, WITHOUT position (so only the BASIS is used) since vectors shouldn't be translated
	var bone_rotate_axis_obj: Vector3 = (bone_transf_obj.basis * bone_rotate_axis).normalized()
	var bone_new_transf_obj: Transform3D = Transform3D(bone_transf_obj.basis.rotated(bone_rotate_axis_obj, bone_rotate_angle), bone_transf_obj.origin)

	skeleton.set_bone_global_pose_override(current_bone_id, bone_new_transf_obj, 0.5, true)

	# Orient this object to the jigglebone
	current_pose_dict[current_bone_id].basis = (skeleton.global_transform * skeleton.get_bone_global_pose(current_bone_id)).basis

func get_bone_forward_local() -> Vector3:
	match forward_axis:
		Axis.X_Plus: return Vector3(1,0,0)
		Axis.Y_Plus: return Vector3(0,1,0)
		Axis.Z_Plus: return Vector3(0,0,1)
		Axis.X_Minus: return Vector3(-1,0,0)
		Axis.Y_Minus: return Vector3(0,-1,0)
		_, Axis.Z_Minus: return Vector3(0,0,-1)
	


func check_for_changes():
	if previous_length != chain_length:
		previous_length = chain_length
		print("change detected")
		setup_bones()
