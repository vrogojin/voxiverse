class_name Player
extends CharacterBody3D
## First-person controller for the grass test env (DESIGN §1).
##
## WASD + run + jump + gravity, mouse-look with browser pointer-lock (Esc frees,
## click re-captures), and a fly/noclip toggle (F). A look-at interaction ray
## reports the voxel the player is aiming at, feeding the thermometer and future
## material inspection.
##
## The world is a pure heightmap, so ground handling is analytic (sample the
## surface height under the player) rather than physics trimesh collision — this
## is cheap, web-friendly, and works identically for both rendering paths. Keys
## are read by physical keycode so no InputMap configuration is required.

signal aimed_voxel_changed(info: Dictionary)

@export var walk_speed := 5.5
@export var run_speed := 9.5
@export var fly_speed := 16.0
@export var jump_velocity := 8.0
@export var gravity := 22.0
@export var eye_height := 1.7
@export var mouse_sensitivity := 0.0025
@export var reach := 8.0

var world: WorldManager                   # injected by Main before _ready
var flying := false

var _camera: Camera3D
var _ray: RayCast3D
var _pitch := 0.0
var _aimed: Dictionary = {}

func _ready() -> void:
	# Build the camera rig in code to keep scenes minimal and robust.
	_camera = Camera3D.new()
	_camera.name = "Camera3D"
	_camera.position = Vector3(0, eye_height, 0)
	_camera.far = float(TerrainConfig.RENDER_RADIUS_BLOCKS) + 32.0
	_camera.fov = 75.0
	add_child(_camera)

	# RayCast3D is present per DESIGN; the authoritative hit test is the analytic
	# voxel DDA in WorldManager (the fallback world has no physics colliders).
	_ray = RayCast3D.new()
	_ray.name = "InteractionRay"
	_ray.target_position = Vector3(0, 0, -reach)
	_ray.enabled = true
	_camera.add_child(_ray)

	# A capsule collider exists for completeness/future physics; movement itself
	# is resolved analytically below.
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.height = 1.8
	capsule.radius = 0.4
	shape.shape = capsule
	shape.position = Vector3(0, 0.9, 0)
	add_child(shape)

	_capture_mouse()

## Set the initial facing (yaw about Y) and camera pitch. Call after the player
## is in the tree (the camera is built in _ready).
func set_initial_look(yaw: float, pitch: float) -> void:
	rotation.y = yaw
	_pitch = clampf(pitch, -1.5, 1.5)
	if _camera != null:
		_camera.rotation.x = _pitch

func _capture_mouse() -> void:
	# Web quirk (Godot #102209): after Esc the pointer won't re-lock unless we
	# cycle through VISIBLE first. Harmless on desktop.
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.5, 1.5)
		_camera.rotation.x = _pitch
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			_capture_mouse()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_F:
				flying = not flying
				velocity = Vector3.ZERO

func _physics_process(delta: float) -> void:
	if world == null:
		return
	_move(delta)
	world.update_streaming(global_position)
	_update_aim()

func _move(delta: float) -> void:
	# Horizontal intent in the player's yaw frame.
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input.z -= 1.0
	if Input.is_key_pressed(KEY_S): input.z += 1.0
	if Input.is_key_pressed(KEY_A): input.x -= 1.0
	if Input.is_key_pressed(KEY_D): input.x += 1.0
	var wish := (transform.basis * Vector3(input.x, 0, input.z))
	wish.y = 0.0
	if wish.length() > 0.0:
		wish = wish.normalized()

	var running := Input.is_key_pressed(KEY_SHIFT)
	if flying:
		var speed := fly_speed * (2.0 if running else 1.0)
		var vy := 0.0
		if Input.is_key_pressed(KEY_SPACE): vy += 1.0
		if Input.is_key_pressed(KEY_CTRL): vy -= 1.0
		global_position += (wish + Vector3(0, vy, 0)) * speed * delta
		velocity = Vector3.ZERO
		return

	var speed := run_speed if running else walk_speed
	global_position += wish * speed * delta

	# Analytic gravity + floor. surface_y() is the top of the grass under us.
	velocity.y -= gravity * delta
	global_position.y += velocity.y * delta
	var floor_y := world.surface_y(global_position.x, global_position.z)
	if global_position.y <= floor_y:
		global_position.y = floor_y
		velocity.y = 0.0
		if Input.is_key_pressed(KEY_SPACE):
			velocity.y = jump_velocity

func _update_aim() -> void:
	var origin := _camera.global_position
	var dir := -_camera.global_transform.basis.z
	var info := world.aimed_voxel(origin, dir, reach)
	if info != _aimed:
		_aimed = info
		aimed_voxel_changed.emit(info)

func get_aimed() -> Dictionary:
	return _aimed

## World position of the air voxel at the player's head (for the air thermometer).
func head_position() -> Vector3:
	return global_position + Vector3(0, eye_height, 0)

## World position just below the feet — the grass voxel the player stands on.
func ground_probe_position() -> Vector3:
	return global_position - Vector3(0, 0.5, 0)
