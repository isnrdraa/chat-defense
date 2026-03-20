extends Node3D

const BASE_MAX_HP := 100.0
const BACKGROUND_COLOR := Color("101820")
const BASE_COLOR := Color("ef8354")
const BASE_WARNING_COLOR := Color("ff595e")
const BULLET_COLOR := Color("ffe066")
const PANEL_COLOR := Color(0.09, 0.13, 0.17, 0.82)
const PANEL_BORDER_COLOR := Color("314455")
const TEXT_PRIMARY := Color("f4f1de")
const TEXT_MUTED := Color("b8c4cf")
const SUPPORT_COLOR := Color("6fffe9")
const SABOTAGE_COLOR := Color("ff7f51")
const ARENA_SIZE := Vector2(1280, 720)
const WORLD_SCALE := 0.032
const PORT := 8787
const MAX_QUEUE_SIZE := 40

const ACTION_COOLDOWNS := {
	"heal_base": 0.8,
	"spawn_turret_temp": 6.0,
	"drop_bomb": 4.0,
	"spawn_runner_pack": 1.2,
	"spawn_tank": 3.5,
	"spawn_ranged_pair": 2.5,
	"fog": 8.0,
	"spawn_boss": 12.0
}

const ENEMY_LIBRARY := {
	"runner": {
		"speed": 90.0,
		"hp": 18.0,
		"damage": 5.0,
		"radius": 12.0,
		"color": Color("7bd389"),
		"bounty": 10
	},
	"tank": {
		"speed": 40.0,
		"hp": 90.0,
		"damage": 14.0,
		"radius": 22.0,
		"color": Color("ff7f51"),
		"bounty": 25
	},
	"ranged": {
		"speed": 55.0,
		"hp": 35.0,
		"damage": 8.0,
		"radius": 16.0,
		"color": Color("5dd9c1"),
		"bounty": 15
	},
	"boss": {
		"speed": 28.0,
		"hp": 300.0,
		"damage": 30.0,
		"radius": 30.0,
		"color": Color("ff006e"),
		"bounty": 80
	}
}

var base_hp := BASE_MAX_HP
var base_position := ARENA_SIZE * 0.5
var base_radius := 42.0
var game_over := false
var restart_timer := 0.0
var elapsed := 0.0
var pulse_time := 0.0
var score := 0
var round_index := 1
var enemy_id_seed := 0
var turret_id_seed := 0
var bullet_id_seed := 0
var wave_timer := 0.0
var event_budget_timer := 0.0
var fog_timer := 0.0
var boss_alert_timer := 0.0
var alert_flash_timer := 0.0
var camera_offset := Vector2.ZERO

var enemies: Array = []
var bullets: Array = []
var turrets: Array = []
var pending_events: Array = []
var event_feed: Array[String] = []
var helper_scores := {}
var saboteur_scores := {}
var raw_http_buffer := {}
var action_timers := {}
var event_router := {}
var enemy_nodes := {}
var turret_nodes := {}
var bullet_nodes := {}

var server := TCPServer.new()
var clients: Array = []

var world_root: Node3D
var arena_root: Node3D
var units_root: Node3D
var projectile_root: Node3D
var base_visual: Node3D
var camera_rig: Node3D
var battle_camera: Camera3D
var fog_plane: MeshInstance3D
var world_environment: WorldEnvironment

var hud_layer: CanvasLayer
var status_panel: Panel
var side_panel: Panel
var bottom_panel: Panel
var flash_overlay: ColorRect
var fog_overlay: ColorRect
var status_label: Label
var scoreboard_label: Label
var controls_label: Label
var feed_label: Label
var bottom_label: Label
var alert_label: Label
var title_label: Label
var audio_player: AudioStreamPlayer
var audio_playback: AudioStreamGeneratorPlayback


func _ready() -> void:
	randomize()
	_create_world()
	_create_hud()
	_setup_audio()
	_load_event_router()
	_start_round()
	var listen_result := server.listen(PORT, "127.0.0.1")
	if listen_result == OK:
		_push_feed("Webhook server listening on 127.0.0.1:%d" % PORT)
	else:
		_push_feed("Webhook server failed to start on port %d" % PORT)
	set_process(true)


func _process(delta: float) -> void:
	_poll_server()
	if game_over:
		restart_timer -= delta
		if restart_timer <= 0.0:
			round_index += 1
			_start_round()
		_sync_world()
		_update_ui()
		return

	elapsed += delta
	pulse_time += delta
	wave_timer += delta
	event_budget_timer += delta
	fog_timer = max(fog_timer - delta, 0.0)
	boss_alert_timer = max(boss_alert_timer - delta, 0.0)
	alert_flash_timer = max(alert_flash_timer - delta, 0.0)
	_tick_action_cooldowns(delta)
	_update_camera_offset()

	_process_waves()
	_process_event_queue()
	_update_turrets(delta)
	_update_bullets(delta)
	_update_enemies(delta)
	_cleanup_entities()
	_sync_world()
	_update_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1:
				_enqueue_action({"action": "heal_base", "user": "local_helper"})
			KEY_2:
				_enqueue_action({"action": "spawn_turret_temp", "user": "local_helper"})
			KEY_3:
				_enqueue_action({"action": "drop_bomb", "user": "local_helper"})
			KEY_8:
				_enqueue_action({"action": "spawn_runner_pack", "user": "local_saboteur"})
			KEY_9:
				_enqueue_action({"action": "spawn_tank", "user": "local_saboteur"})
			KEY_0:
				_enqueue_action({"action": "spawn_boss", "user": "local_saboteur"})
			KEY_R:
				_enqueue_action({"action": "spawn_ranged_pair", "user": "local_saboteur"})
			KEY_F:
				_enqueue_action({"action": "fog", "user": "local_saboteur"})
			KEY_SPACE:
				_start_round()


func _create_world() -> void:
	world_root = Node3D.new()
	add_child(world_root)

	world_environment = WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND_COLOR
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("dbe8ef")
	environment.ambient_light_energy = 1.25
	environment.glow_enabled = true
	environment.glow_intensity = 0.14
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	world_environment.environment = environment
	world_root.add_child(world_environment)

	camera_rig = Node3D.new()
	camera_rig.position = Vector3(0, 0, 1.8)
	world_root.add_child(camera_rig)

	battle_camera = Camera3D.new()
	battle_camera.current = true
	battle_camera.fov = 42.0
	battle_camera.position = Vector3(0, 18.5, 16.0)
	battle_camera.rotation_degrees = Vector3(-52, 0, 0)
	camera_rig.add_child(battle_camera)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 2.0
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-58, -32, 0)
	world_root.add_child(sun)

	var fill_light := OmniLight3D.new()
	fill_light.light_color = Color("6fffe9")
	fill_light.light_energy = 0.55
	fill_light.omni_range = 42.0
	fill_light.position = Vector3(-8, 6, -5)
	world_root.add_child(fill_light)

	var warm_light := OmniLight3D.new()
	warm_light.light_color = Color("ff9a6a")
	warm_light.light_energy = 0.45
	warm_light.omni_range = 44.0
	warm_light.position = Vector3(8, 6, -3)
	world_root.add_child(warm_light)

	arena_root = Node3D.new()
	world_root.add_child(arena_root)

	units_root = Node3D.new()
	world_root.add_child(units_root)

	projectile_root = Node3D.new()
	world_root.add_child(projectile_root)

	_build_arena()

	base_visual = _make_base_node()
	units_root.add_child(base_visual)


func _build_arena() -> void:
	var arena_width: float = ARENA_SIZE.x * WORLD_SCALE
	var arena_depth: float = ARENA_SIZE.y * WORLD_SCALE

	var ground_mesh := PlaneMesh.new()
	ground_mesh.size = Vector2(arena_width, arena_depth)
	var ground := _mesh_instance(ground_mesh, Color("223240"), 0.0, 0.88, true)
	ground.rotation_degrees = Vector3(-90, 0, 0)
	arena_root.add_child(ground)

	var lane_mesh := PlaneMesh.new()
	lane_mesh.size = Vector2(arena_width * 0.74, arena_depth * 0.36)
	var lane := _mesh_instance(lane_mesh, Color(0.35, 0.57, 0.66, 0.22), 0.1, 0.35, true)
	lane.position = Vector3(0, 0.02, 0)
	lane.rotation_degrees = Vector3(-90, 0, 0)
	arena_root.add_child(lane)

	var center_glow_mesh := CylinderMesh.new()
	center_glow_mesh.top_radius = 3.9
	center_glow_mesh.bottom_radius = 3.9
	center_glow_mesh.height = 0.08
	var center_glow := _mesh_instance(center_glow_mesh, Color(0.44, 1.0, 0.91, 0.18), 0.3, 0.2, true)
	center_glow.position = Vector3(0, 0.05, 0)
	arena_root.add_child(center_glow)

	for offset in [-7.8, 7.8]:
		var tower_pad_mesh := CylinderMesh.new()
		tower_pad_mesh.top_radius = 1.25
		tower_pad_mesh.bottom_radius = 1.25
		tower_pad_mesh.height = 0.12
		var tower_pad := _mesh_instance(tower_pad_mesh, Color("20303d"), 0.0, 0.86, false)
		tower_pad.position = Vector3(offset, 0.06, -1.15)
		arena_root.add_child(tower_pad)

	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(arena_width + 1.0, 0.7, 0.55)
	var top_wall := _mesh_instance(wall_mesh, Color("3b4f61"), 0.0, 0.7, false)
	top_wall.position = Vector3(0, 0.35, -arena_depth * 0.5 - 0.1)
	arena_root.add_child(top_wall)
	var bottom_wall := _mesh_instance(wall_mesh, Color("3b4f61"), 0.0, 0.7, false)
	bottom_wall.position = Vector3(0, 0.35, arena_depth * 0.5 + 0.1)
	arena_root.add_child(bottom_wall)

	var side_wall_mesh := BoxMesh.new()
	side_wall_mesh.size = Vector3(0.55, 0.7, arena_depth + 0.35)
	var left_wall := _mesh_instance(side_wall_mesh, Color("3b4f61"), 0.0, 0.7, false)
	left_wall.position = Vector3(-arena_width * 0.5 - 0.1, 0.35, 0)
	arena_root.add_child(left_wall)
	var right_wall := _mesh_instance(side_wall_mesh, Color("3b4f61"), 0.0, 0.7, false)
	right_wall.position = Vector3(arena_width * 0.5 + 0.1, 0.35, 0)
	arena_root.add_child(right_wall)

	fog_plane = _mesh_instance(ground_mesh, Color(0, 0, 0, 0.0), 0.0, 1.0, true)
	fog_plane.rotation_degrees = Vector3(-90, 0, 0)
	fog_plane.position = Vector3(0, 6.5, 0)
	fog_plane.visible = false
	fog_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	arena_root.add_child(fog_plane)


func _create_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

	status_panel = _make_panel(Vector2(10, 8), Vector2(450, 400))
	hud_layer.add_child(status_panel)

	side_panel = _make_panel(Vector2(920, 8), Vector2(345, 610))
	hud_layer.add_child(side_panel)

	bottom_panel = _make_panel(Vector2(10, 644), Vector2(1255, 56))
	hud_layer.add_child(bottom_panel)

	var side_separator_top := ColorRect.new()
	side_separator_top.position = Vector2(920, 54)
	side_separator_top.size = Vector2(345, 2)
	side_separator_top.color = PANEL_BORDER_COLOR
	hud_layer.add_child(side_separator_top)

	var side_separator_bottom := ColorRect.new()
	side_separator_bottom.position = Vector2(920, 302)
	side_separator_bottom.size = Vector2(345, 2)
	side_separator_bottom.color = PANEL_BORDER_COLOR
	hud_layer.add_child(side_separator_bottom)

	title_label = Label.new()
	title_label.position = Vector2(18, 10)
	title_label.size = Vector2(460, 40)
	title_label.add_theme_font_size_override("font_size", 32)
	title_label.modulate = TEXT_PRIMARY
	hud_layer.add_child(title_label)

	status_label = Label.new()
	status_label.position = Vector2(18, 48)
	status_label.size = Vector2(430, 160)
	status_label.add_theme_font_size_override("font_size", 24)
	status_label.modulate = TEXT_PRIMARY
	hud_layer.add_child(status_label)

	scoreboard_label = Label.new()
	scoreboard_label.position = Vector2(18, 212)
	scoreboard_label.size = Vector2(360, 180)
	scoreboard_label.add_theme_font_size_override("font_size", 20)
	scoreboard_label.modulate = TEXT_PRIMARY
	hud_layer.add_child(scoreboard_label)

	controls_label = Label.new()
	controls_label.position = Vector2(935, 66)
	controls_label.size = Vector2(320, 220)
	controls_label.add_theme_font_size_override("font_size", 18)
	controls_label.modulate = TEXT_MUTED
	hud_layer.add_child(controls_label)

	feed_label = Label.new()
	feed_label.position = Vector2(935, 320)
	feed_label.size = Vector2(320, 280)
	feed_label.add_theme_font_size_override("font_size", 18)
	feed_label.modulate = TEXT_PRIMARY
	hud_layer.add_child(feed_label)

	bottom_label = Label.new()
	bottom_label.position = Vector2(18, 655)
	bottom_label.size = Vector2(1240, 40)
	bottom_label.add_theme_font_size_override("font_size", 18)
	bottom_label.modulate = TEXT_MUTED
	hud_layer.add_child(bottom_label)

	alert_label = Label.new()
	alert_label.position = Vector2(350, 28)
	alert_label.size = Vector2(580, 64)
	alert_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	alert_label.add_theme_font_size_override("font_size", 34)
	alert_label.modulate = Color(1, 1, 1, 0)
	hud_layer.add_child(alert_label)

	fog_overlay = ColorRect.new()
	fog_overlay.position = Vector2.ZERO
	fog_overlay.size = ARENA_SIZE
	fog_overlay.color = Color(0, 0, 0, 0)
	fog_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(fog_overlay)

	flash_overlay = ColorRect.new()
	flash_overlay.position = Vector2.ZERO
	flash_overlay.size = ARENA_SIZE
	flash_overlay.color = Color(1, 0.35, 0.4, 0)
	flash_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_layer.add_child(flash_overlay)


func _make_panel(panel_position: Vector2, panel_size: Vector2) -> Panel:
	var panel := Panel.new()
	panel.position = panel_position
	panel.size = panel_size

	var border := StyleBoxFlat.new()
	border.bg_color = PANEL_COLOR
	border.border_width_left = 2
	border.border_width_top = 2
	border.border_width_right = 2
	border.border_width_bottom = 2
	border.border_color = PANEL_BORDER_COLOR
	panel.add_theme_stylebox_override("panel", border)
	return panel


func _setup_audio() -> void:
	audio_player = AudioStreamPlayer.new()
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = 44100
	stream.buffer_length = 0.25
	audio_player.stream = stream
	add_child(audio_player)
	audio_player.play()
	audio_playback = audio_player.get_stream_playback()


func _start_round() -> void:
	base_hp = BASE_MAX_HP
	elapsed = 0.0
	score = 0
	game_over = false
	restart_timer = 0.0
	enemy_id_seed = 0
	turret_id_seed = 0
	bullet_id_seed = 0
	wave_timer = 0.0
	event_budget_timer = 0.0
	fog_timer = 0.0
	boss_alert_timer = 0.0
	alert_flash_timer = 0.0
	camera_offset = Vector2.ZERO
	enemies.clear()
	bullets.clear()
	pending_events.clear()
	event_feed.clear()
	helper_scores.clear()
	saboteur_scores.clear()
	action_timers.clear()
	turrets = []
	_clear_visuals()
	_add_turret(base_position + Vector2(-86, -40), false, 0.0)
	_add_turret(base_position + Vector2(86, -40), false, 0.0)
	_push_feed("Round %d started" % round_index)
	_sync_world()


func _process_waves() -> void:
	var cadence: float = max(0.55, 1.8 - elapsed * 0.012)
	if wave_timer < cadence:
		return
	wave_timer = 0.0
	var difficulty := 1 + int(elapsed / 25.0)
	for _i in range(difficulty):
		_spawn_enemy("runner")
	if elapsed >= 20.0 and randi() % 3 == 0:
		_spawn_enemy("ranged")
	if elapsed >= 45.0 and randi() % 4 == 0:
		_spawn_enemy("tank")
	if elapsed >= 90.0 and int(elapsed) % 30 == 0:
		_spawn_enemy("boss")
		_push_feed("System spawned a boss wave")


func _process_event_queue() -> void:
	if pending_events.is_empty():
		return
	if event_budget_timer < 0.18:
		return
	event_budget_timer = 0.0
	var payload: Dictionary = pending_events.pop_front()
	var action := String(payload.get("action", ""))
	var user := String(payload.get("user", "viewer"))

	match action:
		"heal_base":
			base_hp = clamp(base_hp + 12.0, 0.0, BASE_MAX_HP)
			_add_score(helper_scores, user)
			_push_feed("%s healed the base" % user)
			_play_tone(660.0, 0.08, 0.12)
		"spawn_turret_temp":
			var angle := randf() * TAU
			_add_turret(base_position + Vector2.RIGHT.rotated(angle) * 140.0, true, 28.0)
			_add_score(helper_scores, user)
			_push_feed("%s deployed a temp turret" % user)
			_show_alert("TURRET DROP", SUPPORT_COLOR, 1.0)
			_play_tone(740.0, 0.1, 0.14)
		"drop_bomb":
			var removed := _damage_enemies_in_radius(base_position, 170.0, 45.0)
			score += removed * 8
			_add_score(helper_scores, user)
			_push_feed("%s dropped a bomb" % user)
			alert_flash_timer = 0.22
			_show_alert("BOMB BLAST", BULLET_COLOR, 0.8)
			_play_tone(520.0, 0.12, 0.18)
		"spawn_runner_pack":
			for _i in range(4):
				_spawn_enemy("runner")
			_add_score(saboteur_scores, user)
			_push_feed("%s unleashed runners" % user)
			_play_tone(240.0, 0.09, 0.12)
		"spawn_tank":
			_spawn_enemy("tank")
			_add_score(saboteur_scores, user)
			_push_feed("%s spawned a tank" % user)
			_show_alert("TANK INBOUND", SABOTAGE_COLOR, 0.9)
			_play_tone(180.0, 0.16, 0.16)
		"spawn_ranged_pair":
			_spawn_enemy("ranged")
			_spawn_enemy("ranged")
			_add_score(saboteur_scores, user)
			_push_feed("%s sent ranged enemies" % user)
			_play_tone(280.0, 0.11, 0.12)
		"fog":
			fog_timer = 8.0
			_add_score(saboteur_scores, user)
			_push_feed("%s triggered blackout fog" % user)
			_show_alert("BLACKOUT", Color("9aa6b2"), 1.0)
			_play_tone(130.0, 0.2, 0.14)
		"spawn_boss":
			_spawn_enemy("boss")
			_add_score(saboteur_scores, user)
			_push_feed("%s summoned a boss" % user)
			_trigger_boss_alert("BOSS SUMMONED")


func _update_turrets(delta: float) -> void:
	for turret in turrets:
		turret["cooldown"] = max(float(turret["cooldown"]) - delta, 0.0)
		if bool(turret["temporary"]):
			turret["ttl"] = float(turret["ttl"]) - delta
		if float(turret["cooldown"]) > 0.0:
			continue
		var target := _find_nearest_enemy(turret["position"], turret["range"])
		if target.is_empty():
			continue
		turret["cooldown"] = turret["fire_rate"]
		var to_target: Vector2 = target["position"] - turret["position"]
		var velocity := to_target.normalized() * float(turret["bullet_speed"])
		bullet_id_seed += 1
		bullets.append({
			"id": bullet_id_seed,
			"position": turret["position"],
			"velocity": velocity,
			"damage": turret["damage"],
			"radius": 4.0,
			"life": 2.1
		})


func _update_bullets(delta: float) -> void:
	for bullet in bullets:
		bullet["position"] += bullet["velocity"] * delta
		bullet["life"] = float(bullet["life"]) - delta
		for enemy in enemies:
			if float(enemy["hp"]) <= 0.0:
				continue
			if bullet["position"].distance_to(enemy["position"]) <= float(enemy["radius"]) + float(bullet["radius"]):
				enemy["hp"] = float(enemy["hp"]) - float(bullet["damage"])
				bullet["life"] = 0.0
				break


func _update_enemies(delta: float) -> void:
	for enemy in enemies:
		if float(enemy["hp"]) <= 0.0:
			continue
		var to_base: Vector2 = base_position - enemy["position"]
		var stop_distance := base_radius + float(enemy["radius"]) + 4.0
		if to_base.length() > stop_distance:
			enemy["position"] += to_base.normalized() * float(enemy["speed"]) * delta
			continue
		enemy["attack_cooldown"] = float(enemy["attack_cooldown"]) - delta
		if float(enemy["attack_cooldown"]) <= 0.0:
			base_hp -= float(enemy["damage"])
			enemy["attack_cooldown"] = enemy["attack_rate"]
			if base_hp <= 0.0:
				base_hp = 0.0
				_trigger_game_over()
				return


func _cleanup_entities() -> void:
	var alive_enemies: Array = []
	for enemy in enemies:
		if float(enemy["hp"]) <= 0.0:
			score += int(enemy["bounty"])
			continue
		alive_enemies.append(enemy)
	enemies = alive_enemies

	var alive_bullets: Array = []
	for bullet in bullets:
		if float(bullet["life"]) > 0.0:
			alive_bullets.append(bullet)
	bullets = alive_bullets

	var active_turrets: Array = []
	for turret in turrets:
		if bool(turret["temporary"]) and float(turret["ttl"]) <= 0.0:
			continue
		active_turrets.append(turret)
	turrets = active_turrets


func _trigger_game_over() -> void:
	game_over = true
	restart_timer = 7.0
	_push_feed("Base destroyed. Restarting in %.0f" % restart_timer)
	_show_alert("BASE DESTROYED", BASE_WARNING_COLOR, 2.6)
	_play_tone(120.0, 0.35, 0.18)


func _spawn_enemy(kind: String) -> void:
	if enemies.size() >= 80:
		return
	var template: Dictionary = ENEMY_LIBRARY.get(kind, {})
	if template.is_empty():
		return
	enemy_id_seed += 1
	var spawn_position := _pick_spawn_position()
	enemies.append({
		"id": enemy_id_seed,
		"type": kind,
		"position": spawn_position,
		"hp": template["hp"],
		"speed": template["speed"],
		"damage": template["damage"],
		"radius": template["radius"],
		"color": template["color"],
		"attack_rate": 0.9 if kind == "runner" else 1.3,
		"attack_cooldown": 0.6,
		"bounty": template["bounty"]
	})


func _add_turret(turret_position: Vector2, temporary: bool, ttl: float) -> void:
	turret_id_seed += 1
	turrets.append({
		"id": turret_id_seed,
		"position": turret_position,
		"range": 260.0,
		"fire_rate": 0.24 if temporary else 0.32,
		"cooldown": 0.3,
		"damage": 15.0 if temporary else 12.0,
		"bullet_speed": 420.0,
		"temporary": temporary,
		"ttl": ttl
	})


func _pick_spawn_position() -> Vector2:
	match randi() % 4:
		0:
			return Vector2(randf_range(0.0, ARENA_SIZE.x), -20.0)
		1:
			return Vector2(ARENA_SIZE.x + 20.0, randf_range(0.0, ARENA_SIZE.y))
		2:
			return Vector2(randf_range(0.0, ARENA_SIZE.x), ARENA_SIZE.y + 20.0)
		_:
			return Vector2(-20.0, randf_range(0.0, ARENA_SIZE.y))


func _find_nearest_enemy(origin: Vector2, max_range: float) -> Dictionary:
	var nearest: Dictionary = {}
	var nearest_distance := max_range
	for enemy in enemies:
		if float(enemy["hp"]) <= 0.0:
			continue
		var distance := origin.distance_to(enemy["position"])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = enemy
	return nearest


func _damage_enemies_in_radius(center: Vector2, radius: float, damage: float) -> int:
	var kills := 0
	for enemy in enemies:
		if float(enemy["hp"]) <= 0.0:
			continue
		if center.distance_to(enemy["position"]) <= radius + float(enemy["radius"]):
			enemy["hp"] = float(enemy["hp"]) - damage
			if float(enemy["hp"]) <= 0.0:
				kills += 1
	return kills


func _sync_world() -> void:
	_sync_base_visual()
	_sync_turret_visuals()
	_sync_enemy_visuals()
	_sync_bullet_visuals()
	_sync_overlays()


func _sync_base_visual() -> void:
	base_visual.position = _world_pos(base_position, 0.24)
	var hp_ratio: float = clamp(base_hp / BASE_MAX_HP, 0.0, 1.0)
	var core := base_visual.get_node("Core") as MeshInstance3D
	var core_material := core.material_override as StandardMaterial3D
	var core_color := BASE_COLOR if hp_ratio > 0.3 else BASE_WARNING_COLOR
	core_material.albedo_color = core_color
	core_material.emission = core_color
	core_material.emission_energy_multiplier = 0.55 + (1.0 - hp_ratio) * 0.55
	base_visual.rotation.y = pulse_time * 0.32
	base_visual.scale = Vector3.ONE * (1.0 + sin(pulse_time * 2.4) * 0.015)


func _sync_turret_visuals() -> void:
	var active_ids := {}
	for turret in turrets:
		var turret_id := int(turret["id"])
		active_ids[turret_id] = true
		var turret_node: Node3D = turret_nodes.get(turret_id)
		if turret_node == null:
			turret_node = _make_turret_node(bool(turret["temporary"]))
			turret_nodes[turret_id] = turret_node
			units_root.add_child(turret_node)
		var bob := 0.08 * sin(pulse_time * 3.2 + float(turret_id))
		turret_node.position = _world_pos(turret["position"], 0.18 + bob)
		var turret_head := turret_node.get_node("Head") as Node3D
		var target := _find_nearest_enemy(turret["position"], turret["range"])
		if not target.is_empty():
			var look_target := _world_pos(target["position"], turret_node.position.y)
			turret_head.look_at(look_target, Vector3.UP, true)
		var glow := turret_node.get_node("Glow") as MeshInstance3D
		var glow_material := glow.material_override as StandardMaterial3D
		if bool(turret["temporary"]):
			glow_material.albedo_color = Color(0.44, 1.0, 0.91, 0.28 + 0.08 * sin(pulse_time * 6.0))
		else:
			glow_material.albedo_color = Color(0.96, 0.95, 0.87, 0.18)
	for turret_id in turret_nodes.keys().duplicate():
		if not active_ids.has(turret_id):
			var old_turret: Node3D = turret_nodes[turret_id]
			old_turret.queue_free()
			turret_nodes.erase(turret_id)


func _sync_enemy_visuals() -> void:
	var active_ids := {}
	for enemy in enemies:
		var enemy_id := int(enemy["id"])
		active_ids[enemy_id] = true
		var enemy_node: Node3D = enemy_nodes.get(enemy_id)
		if enemy_node == null:
			enemy_node = _make_enemy_node(String(enemy["type"]), enemy["color"])
			enemy_nodes[enemy_id] = enemy_node
			units_root.add_child(enemy_node)
		var hover := 0.08 * sin(pulse_time * 4.2 + float(enemy_id) * 0.4)
		enemy_node.position = _world_pos(enemy["position"], 0.2 + hover)
		var base_world := _world_pos(base_position, enemy_node.position.y)
		enemy_node.look_at(Vector3(base_world.x, enemy_node.position.y, base_world.z), Vector3.UP, true)
		var hp_ratio: float = clamp(float(enemy["hp"]) / float(ENEMY_LIBRARY[String(enemy["type"])]["hp"]), 0.0, 1.0)
		var hp_fill := enemy_node.get_node("HP/Fill") as MeshInstance3D
		hp_fill.scale.x = max(hp_ratio, 0.02)
		hp_fill.position.x = -0.6 + hp_ratio * 0.6
	for enemy_id in enemy_nodes.keys().duplicate():
		if not active_ids.has(enemy_id):
			var old_enemy: Node3D = enemy_nodes[enemy_id]
			old_enemy.queue_free()
			enemy_nodes.erase(enemy_id)


func _sync_bullet_visuals() -> void:
	var active_ids := {}
	for bullet in bullets:
		var bullet_id := int(bullet["id"])
		active_ids[bullet_id] = true
		var bullet_node: Node3D = bullet_nodes.get(bullet_id)
		if bullet_node == null:
			bullet_node = _make_bullet_node()
			bullet_nodes[bullet_id] = bullet_node
			projectile_root.add_child(bullet_node)
		bullet_node.position = _world_pos(bullet["position"], 0.52)
		bullet_node.scale = Vector3.ONE * (0.85 + 0.2 * sin(pulse_time * 14.0 + float(bullet_id)))
	for bullet_id in bullet_nodes.keys().duplicate():
		if not active_ids.has(bullet_id):
			var old_bullet: Node3D = bullet_nodes[bullet_id]
			old_bullet.queue_free()
			bullet_nodes.erase(bullet_id)


func _sync_overlays() -> void:
	camera_rig.position = Vector3(camera_offset.x * WORLD_SCALE * 0.18, 0, 1.8 + camera_offset.y * WORLD_SCALE * 0.12)
	if fog_timer > 0.0:
		var fog_alpha: float = 0.18 + 0.1 * sin(pulse_time * 2.0)
		fog_plane.visible = true
		var fog_material := fog_plane.material_override as StandardMaterial3D
		fog_material.albedo_color = Color(0.02, 0.04, 0.06, fog_alpha)
		fog_overlay.color = Color(0, 0, 0, 0.16)
	else:
		fog_plane.visible = false
		fog_overlay.color = Color(0, 0, 0, 0)
	if alert_flash_timer > 0.0:
		var flash_alpha := 0.1 + 0.12 * sin(pulse_time * 24.0)
		flash_overlay.color = Color(1, 0.35, 0.4, flash_alpha)
	else:
		flash_overlay.color = Color(1, 0.35, 0.4, 0)


func _make_base_node() -> Node3D:
	var root := Node3D.new()

	var foundation_mesh := CylinderMesh.new()
	foundation_mesh.top_radius = 1.85
	foundation_mesh.bottom_radius = 2.05
	foundation_mesh.height = 0.42
	var foundation := _mesh_instance(foundation_mesh, Color("263847"), 0.0, 0.78, false)
	root.add_child(foundation)

	var ring_mesh := CylinderMesh.new()
	ring_mesh.top_radius = 2.35
	ring_mesh.bottom_radius = 2.35
	ring_mesh.height = 0.08
	var ring := _mesh_instance(ring_mesh, Color(0.44, 1.0, 0.91, 0.18), 0.35, 0.22, true)
	ring.position = Vector3(0, -0.12, 0)
	root.add_child(ring)

	var core_mesh := SphereMesh.new()
	core_mesh.radius = 0.92
	core_mesh.height = 1.7
	var core := _mesh_instance(core_mesh, BASE_COLOR, 0.65, 0.2, false)
	core.name = "Core"
	core.position = Vector3(0, 0.92, 0)
	root.add_child(core)

	var crown_mesh := BoxMesh.new()
	crown_mesh.size = Vector3(0.28, 1.45, 0.28)
	for angle in [0.0, 45.0, 90.0, 135.0]:
		var crown := _mesh_instance(crown_mesh, Color("ffe5d6"), 0.0, 0.28, false)
		crown.position = Vector3(0, 1.15, 0)
		crown.rotation_degrees = Vector3(0, angle, 0)
		root.add_child(crown)

	return root


func _make_turret_node(temporary: bool) -> Node3D:
	var root := Node3D.new()

	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 0.82
	glow_mesh.bottom_radius = 0.82
	glow_mesh.height = 0.06
	var glow_color := Color(0.44, 1.0, 0.91, 0.24) if temporary else Color(0.96, 0.95, 0.87, 0.18)
	var glow := _mesh_instance(glow_mesh, glow_color, 0.25, 0.16, true)
	glow.name = "Glow"
	glow.position = Vector3(0, -0.07, 0)
	root.add_child(glow)

	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 0.48
	base_mesh.bottom_radius = 0.58
	base_mesh.height = 0.46
	var base_color := Color("6fffe9") if temporary else Color("f4f1de")
	var base := _mesh_instance(base_mesh, base_color, 0.1 if temporary else 0.0, 0.46, false)
	base.position = Vector3(0, 0.2, 0)
	root.add_child(base)

	var head := Node3D.new()
	head.name = "Head"
	head.position = Vector3(0, 0.48, 0)
	root.add_child(head)

	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.42, 0.26, 0.54)
	var head_body := _mesh_instance(head_mesh, Color("314455"), 0.0, 0.48, false)
	head.add_child(head_body)

	var barrel_mesh := CylinderMesh.new()
	barrel_mesh.top_radius = 0.08
	barrel_mesh.bottom_radius = 0.08
	barrel_mesh.height = 0.9
	var barrel := _mesh_instance(barrel_mesh, base_color, 0.08 if temporary else 0.0, 0.3, false)
	barrel.rotation_degrees = Vector3(90, 0, 0)
	barrel.position = Vector3(0, 0.02, -0.5)
	head.add_child(barrel)

	return root


func _make_enemy_node(kind: String, tint: Color) -> Node3D:
	var root := Node3D.new()

	match kind:
		"tank":
			var body_mesh := BoxMesh.new()
			body_mesh.size = Vector3(1.2, 0.8, 1.45)
			var body := _mesh_instance(body_mesh, tint, 0.18, 0.58, false)
			body.position = Vector3(0, 0.46, 0)
			root.add_child(body)

			var turret_mesh := CylinderMesh.new()
			turret_mesh.top_radius = 0.34
			turret_mesh.bottom_radius = 0.42
			turret_mesh.height = 0.42
			var turret := _mesh_instance(turret_mesh, Color("552214"), 0.0, 0.64, false)
			turret.position = Vector3(0, 0.95, -0.08)
			root.add_child(turret)

			var horn_mesh := BoxMesh.new()
			horn_mesh.size = Vector3(0.2, 0.2, 0.8)
			var horn := _mesh_instance(horn_mesh, Color("ffe3d9"), 0.0, 0.28, false)
			horn.position = Vector3(0, 0.96, -0.65)
			root.add_child(horn)
		"ranged":
			var body_capsule := CapsuleMesh.new()
			body_capsule.radius = 0.42
			body_capsule.height = 1.15
			var body_ranged := _mesh_instance(body_capsule, tint, 0.24, 0.42, false)
			body_ranged.position = Vector3(0, 0.72, 0)
			root.add_child(body_ranged)

			var orb_mesh := SphereMesh.new()
			orb_mesh.radius = 0.18
			orb_mesh.height = 0.36
			var orb := _mesh_instance(orb_mesh, Color("e7fffb"), 0.7, 0.1, false)
			orb.position = Vector3(0, 1.38, -0.12)
			root.add_child(orb)
		"boss":
			var core_mesh := SphereMesh.new()
			core_mesh.radius = 0.88
			core_mesh.height = 1.76
			var core := _mesh_instance(core_mesh, tint, 0.52, 0.22, false)
			core.position = Vector3(0, 1.08, 0)
			root.add_child(core)

			var crown_mesh := BoxMesh.new()
			crown_mesh.size = Vector3(0.16, 0.86, 0.16)
			for angle in [0.0, 45.0, 90.0, 135.0]:
				var spike := _mesh_instance(crown_mesh, Color("ffd3e6"), 0.1, 0.24, false)
				spike.position = Vector3(0, 1.8, 0)
				spike.rotation_degrees = Vector3(18, angle, 0)
				root.add_child(spike)
		_:
			var runner_capsule := CapsuleMesh.new()
			runner_capsule.radius = 0.3
			runner_capsule.height = 0.92
			var runner_body := _mesh_instance(runner_capsule, tint, 0.16, 0.35, false)
			runner_body.position = Vector3(0, 0.58, 0)
			root.add_child(runner_body)

			var runner_head_mesh := SphereMesh.new()
			runner_head_mesh.radius = 0.18
			runner_head_mesh.height = 0.36
			var runner_head := _mesh_instance(runner_head_mesh, Color("e9fff1"), 0.0, 0.2, false)
			runner_head.position = Vector3(0, 1.1, -0.08)
			root.add_child(runner_head)

	var hp_root := Node3D.new()
	hp_root.name = "HP"
	hp_root.position = Vector3(0, 1.8 if kind == "boss" else 1.35, 0)
	root.add_child(hp_root)

	var hp_back_mesh := BoxMesh.new()
	hp_back_mesh.size = Vector3(1.2, 0.08, 0.08)
	var hp_back := _mesh_instance(hp_back_mesh, Color(0, 0, 0, 0.42), 0.0, 0.9, true)
	hp_root.add_child(hp_back)

	var hp_fill_mesh := BoxMesh.new()
	hp_fill_mesh.size = Vector3(1.2, 0.08, 0.08)
	var hp_fill := _mesh_instance(hp_fill_mesh, Color("e0fbfc"), 0.2, 0.3, false)
	hp_fill.name = "Fill"
	hp_fill.position = Vector3(0, 0.01, -0.01)
	hp_root.add_child(hp_fill)

	return root


func _make_bullet_node() -> Node3D:
	var root := Node3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.16
	sphere_mesh.height = 0.32
	var sphere := _mesh_instance(sphere_mesh, BULLET_COLOR, 0.95, 0.08, false)
	root.add_child(sphere)

	var halo_mesh := SphereMesh.new()
	halo_mesh.radius = 0.24
	halo_mesh.height = 0.48
	var halo := _mesh_instance(halo_mesh, Color(BULLET_COLOR.r, BULLET_COLOR.g, BULLET_COLOR.b, 0.16), 0.4, 0.05, true)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(halo)
	return root


func _mesh_instance(mesh: Mesh, color: Color, emission_energy: float, roughness: float, transparent: bool) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color, emission_energy, roughness, transparent)
	return instance


func _material(color: Color, emission_energy: float, roughness: float, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = 0.08
	if transparent or color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if emission_energy > 0.0:
		material.emission_enabled = true
		material.emission = color
		material.emission_energy_multiplier = emission_energy
	return material


func _world_pos(point: Vector2, height: float) -> Vector3:
	var centered := point - ARENA_SIZE * 0.5
	return Vector3(centered.x * WORLD_SCALE, height, centered.y * WORLD_SCALE)


func _clear_visuals() -> void:
	for enemy_id in enemy_nodes.keys():
		var enemy_node = enemy_nodes[enemy_id]
		enemy_node.queue_free()
	enemy_nodes.clear()
	for turret_id in turret_nodes.keys():
		var turret_node = turret_nodes[turret_id]
		turret_node.queue_free()
	turret_nodes.clear()
	for bullet_id in bullet_nodes.keys():
		var bullet_node = bullet_nodes[bullet_id]
		bullet_node.queue_free()
	bullet_nodes.clear()


func _update_ui() -> void:
	var live_status := "LIVE" if not game_over else "ROUND OVER"
	title_label.text = "CHAT DEFENSE 3D"
	status_label.text = "Status  %s\nRound   %d\nScore   %d\nBase    %.0f / %.0f HP\nTimer   %.1fs\nThreat  %d enemies\nQueue   %d events" % [
		live_status,
		round_index,
		score,
		base_hp,
		BASE_MAX_HP,
		elapsed,
		enemies.size(),
		pending_events.size()
	]
	scoreboard_label.text = "SUPPORTERS\n%s\n\nSABOTEURS\n%s" % [
		_format_top_scores(helper_scores),
		_format_top_scores(saboteur_scores)
	]
	controls_label.text = "LOCAL TEST KEYS\n1  Heal Base\n2  Temp Turret\n3  Bomb\n8  Runner Pack\n9  Tank\n0  Boss\nR  Ranged Pair\nF  Fog\nSpace  Restart"
	feed_label.text = "LIVE EVENT FEED\n%s" % "\n".join(event_feed)
	bottom_label.text = "Webhook: POST http://127.0.0.1:%d/event with JSON {\"action\":\"spawn_tank\",\"user\":\"nama_viewer\"}" % PORT
	if boss_alert_timer > 0.0:
		alert_label.modulate = Color(1, 1, 1, 0.9 + 0.1 * sin(pulse_time * 18.0))
	elif alert_flash_timer > 0.0:
		alert_label.modulate = Color(1, 1, 1, 0.75)
	else:
		alert_label.modulate = Color(1, 1, 1, 0.0)


func _tick_action_cooldowns(delta: float) -> void:
	for action in action_timers.keys():
		action_timers[action] = max(float(action_timers[action]) - delta, 0.0)


func _load_event_router() -> void:
	var router_path := "res://config/event_router.json"
	if not FileAccess.file_exists(router_path):
		event_router = {}
		_push_feed("Router config not found, using direct actions only")
		return
	var json_text := FileAccess.get_file_as_string(router_path)
	var parsed = JSON.parse_string(json_text)
	if typeof(parsed) != TYPE_DICTIONARY:
		event_router = {}
		_push_feed("Router config invalid, using direct actions only")
		return
	event_router = parsed
	_push_feed("Loaded event router config")


func _format_top_scores(bucket: Dictionary) -> String:
	if bucket.is_empty():
		return "-"
	var lines: Array[String] = []
	var keys := bucket.keys()
	keys.sort_custom(func(a, b): return bucket[a] > bucket[b])
	for i in range(min(3, keys.size())):
		var key = keys[i]
		lines.append("%s  %d" % [key, bucket[key]])
	return "\n".join(lines)


func _add_score(bucket: Dictionary, user: String) -> void:
	bucket[user] = int(bucket.get(user, 0)) + 1


func _push_feed(message: String) -> void:
	event_feed.push_front(message)
	if event_feed.size() > 10:
		event_feed = event_feed.slice(0, 10)


func _enqueue_action(payload: Dictionary) -> void:
	if game_over:
		return
	var action := String(payload.get("action", ""))
	if not ACTION_COOLDOWNS.has(action):
		return
	if pending_events.size() >= MAX_QUEUE_SIZE:
		return
	if float(action_timers.get(action, 0.0)) > 0.0:
		return
	action_timers[action] = ACTION_COOLDOWNS[action]
	pending_events.append(payload)


func _show_alert(message: String, color: Color, duration: float) -> void:
	alert_label.text = message
	alert_label.self_modulate = color
	alert_flash_timer = max(alert_flash_timer, duration)


func _trigger_boss_alert(message: String) -> void:
	_show_alert(message, BASE_WARNING_COLOR, 2.4)
	boss_alert_timer = 2.4
	alert_flash_timer = 1.2
	_play_tone(220.0, 0.18, 0.18)
	_play_tone(330.0, 0.22, 0.18)


func _update_camera_offset() -> void:
	if boss_alert_timer > 0.0:
		var shake_strength := 5.0 * (boss_alert_timer / 2.4)
		camera_offset = Vector2(randf_range(-shake_strength, shake_strength), randf_range(-shake_strength, shake_strength))
		return
	camera_offset = Vector2.ZERO


func _play_tone(frequency: float, duration: float, amplitude: float) -> void:
	if audio_playback == null:
		return
	var generator := audio_player.stream as AudioStreamGenerator
	if generator == null:
		return
	var frame_count := int(generator.mix_rate * duration)
	for i in range(frame_count):
		var t: float = float(i) / generator.mix_rate
		var envelope_divisor: float = float(max(frame_count, 1))
		var envelope: float = 1.0 - (float(i) / envelope_divisor)
		var sample: float = sin(TAU * frequency * t) * amplitude * envelope
		audio_playback.push_frame(Vector2(sample, sample))


func enqueue_external_event(payload: Dictionary) -> void:
	var action := _resolve_external_action(payload)
	if action.is_empty():
		return
	var user := String(payload.get("user", "viewer"))
	_enqueue_action({
		"action": action,
		"user": user
	})


func _resolve_external_action(payload: Dictionary) -> String:
	if payload.has("action"):
		return String(payload.get("action", ""))
	var event_type := String(payload.get("type", "")).to_lower()
	match event_type:
		"comment":
			var comment_text := String(payload.get("comment", payload.get("text", payload.get("keyword", "")))).strip_edges().to_lower()
			var comments: Dictionary = event_router.get("comments", {})
			if comments.has(comment_text):
				return String(comments[comment_text])
		"gift":
			var gift_name := String(payload.get("gift", payload.get("name", ""))).strip_edges()
			var gifts: Dictionary = event_router.get("gifts", {})
			if gifts.has(gift_name):
				return String(gifts[gift_name])
		"follow":
			return String(event_router.get("follow_action", ""))
		"like":
			var like_count := int(payload.get("count", payload.get("likes", 0)))
			var like_rules: Array = event_router.get("likes", [])
			for rule in like_rules:
				if like_count >= int(rule.get("min_count", 0)):
					return String(rule.get("action", ""))
	return ""


func _poll_server() -> void:
	while server.is_connection_available():
		var client := server.take_connection()
		if client != null:
			clients.append(client)
	for client in clients.duplicate():
		if client.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(client)
			raw_http_buffer.erase(client)
			continue
		var bytes: int = client.get_available_bytes()
		if bytes <= 0:
			continue
		var incoming: String = client.get_utf8_string(bytes)
		raw_http_buffer[client] = String(raw_http_buffer.get(client, "")) + incoming
		var request_text := String(raw_http_buffer[client])
		if not request_text.contains("\r\n\r\n"):
			continue
		if not _http_request_complete(request_text):
			continue
		var response := _handle_http_payload(request_text)
		client.put_data(response.to_utf8_buffer())
		client.disconnect_from_host()
		clients.erase(client)
		raw_http_buffer.erase(client)


func _handle_http_payload(request_text: String) -> String:
	var sections := request_text.split("\r\n\r\n", false, 1)
	var headers := sections[0]
	var body := sections[1] if sections.size() > 1 else ""
	var first_line := headers.split("\r\n", false)[0]
	var parts := first_line.split(" ")
	if parts.size() < 2:
		return _http_response(400, "{\"ok\":false,\"error\":\"invalid request\"}")
	var method := parts[0]
	var path := parts[1]
	if method != "POST" or path != "/event":
		return _http_response(404, "{\"ok\":false,\"error\":\"not found\"}")
	var parsed = JSON.parse_string(body)
	if typeof(parsed) != TYPE_DICTIONARY:
		return _http_response(400, "{\"ok\":false,\"error\":\"invalid json\"}")
	enqueue_external_event(parsed)
	return _http_response(200, "{\"ok\":true}")


func _http_request_complete(request_text: String) -> bool:
	var sections := request_text.split("\r\n\r\n", false, 1)
	if sections.size() < 2:
		return false
	var headers := sections[0]
	var body := sections[1]
	var content_length := 0
	for header_line in headers.split("\r\n", false):
		if header_line.to_lower().begins_with("content-length:"):
			content_length = int(header_line.split(":", false, 1)[1].strip_edges())
			break
	return body.to_utf8_buffer().size() >= content_length


func _http_response(code: int, body: String) -> String:
	var status := "OK" if code == 200 else "ERROR"
	return "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % [
		code,
		status,
		body.length(),
		body
	]
