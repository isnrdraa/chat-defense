extends Node2D

const BASE_MAX_HP := 100.0
const BACKGROUND_COLOR := Color("101820")
const GRID_COLOR := Color(1, 1, 1, 0.05)
const BASE_COLOR := Color("ef8354")
const BASE_WARNING_COLOR := Color("ff595e")
const BULLET_COLOR := Color("ffe066")
const PANEL_COLOR := Color("16212b")
const PANEL_BORDER_COLOR := Color("314455")
const TEXT_PRIMARY := Color("f4f1de")
const TEXT_MUTED := Color("b8c4cf")
const SUPPORT_COLOR := Color("6fffe9")
const SABOTAGE_COLOR := Color("ff7f51")
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
var base_position := Vector2.ZERO
var base_radius := 42.0
var game_over := false
var restart_timer := 0.0
var elapsed := 0.0
var pulse_time := 0.0
var score := 0
var round_index := 1
var enemy_id_seed := 0
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

var server := TCPServer.new()
var clients: Array = []

var hud_layer: CanvasLayer
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
	base_position = get_viewport_rect().size * 0.5
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
		_update_ui()
		queue_redraw()
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
	_update_ui()
	queue_redraw()


func _draw() -> void:
	var view_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view_size), BACKGROUND_COLOR, true)
	_draw_backdrop(view_size)
	_draw_grid(view_size)
	draw_set_transform(camera_offset, 0.0, Vector2.ONE)
	_draw_spawn_rings()
	_draw_turrets()
	_draw_bullets()
	_draw_enemies()
	_draw_base()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if fog_timer > 0.0:
		draw_rect(Rect2(Vector2.ZERO, view_size), Color(0, 0, 0, 0.32), true)
	if alert_flash_timer > 0.0:
		var alpha := 0.1 + 0.12 * sin(pulse_time * 24.0)
		draw_rect(Rect2(Vector2.ZERO, view_size), Color(1, 0.35, 0.4, alpha), true)


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


func _create_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

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
	_add_turret(base_position + Vector2(-86, -40), false, 0.0)
	_add_turret(base_position + Vector2(86, -40), false, 0.0)
	_push_feed("Round %d started" % round_index)


func _process_waves() -> void:
	var cadence := max(0.55, 1.8 - elapsed * 0.012)
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
		bullets.append({
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


func _add_turret(position: Vector2, temporary: bool, ttl: float) -> void:
	turrets.append({
		"position": position,
		"range": 260.0,
		"fire_rate": 0.24 if temporary else 0.32,
		"cooldown": 0.3,
		"damage": 15.0 if temporary else 12.0,
		"bullet_speed": 420.0,
		"temporary": temporary,
		"ttl": ttl
	})


func _pick_spawn_position() -> Vector2:
	var size := get_viewport_rect().size
	match randi() % 4:
		0:
			return Vector2(randf_range(0.0, size.x), -20.0)
		1:
			return Vector2(size.x + 20.0, randf_range(0.0, size.y))
		2:
			return Vector2(randf_range(0.0, size.x), size.y + 20.0)
		_:
			return Vector2(-20.0, randf_range(0.0, size.y))


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


func _draw_grid(view_size: Vector2) -> void:
	for x in range(0, int(view_size.x), 64):
		draw_line(Vector2(x, 0), Vector2(x, view_size.y), GRID_COLOR, 1.0)
	for y in range(0, int(view_size.y), 64):
		draw_line(Vector2(0, y), Vector2(view_size.x, y), GRID_COLOR, 1.0)


func _draw_backdrop(view_size: Vector2) -> void:
	draw_circle(Vector2(210, 120), 180.0, Color(0.07, 0.45, 0.44, 0.10))
	draw_circle(Vector2(view_size.x - 120, 160), 220.0, Color(0.93, 0.51, 0.32, 0.08))
	draw_rect(Rect2(10, 8, 450, 400), PANEL_COLOR, true)
	draw_rect(Rect2(10, 8, 450, 400), PANEL_BORDER_COLOR, false, 2.0)
	draw_rect(Rect2(920, 8, 345, 610), PANEL_COLOR, true)
	draw_rect(Rect2(920, 8, 345, 610), PANEL_BORDER_COLOR, false, 2.0)
	draw_rect(Rect2(10, 644, 1255, 56), PANEL_COLOR, true)
	draw_rect(Rect2(10, 644, 1255, 56), PANEL_BORDER_COLOR, false, 2.0)
	draw_line(Vector2(920, 54), Vector2(1265, 54), PANEL_BORDER_COLOR, 2.0)
	draw_line(Vector2(920, 302), Vector2(1265, 302), PANEL_BORDER_COLOR, 2.0)


func _draw_spawn_rings() -> void:
	var ring_pulse := 0.04 + 0.03 * (0.5 + 0.5 * sin(pulse_time * 2.5))
	draw_arc(base_position, 140.0, 0.0, TAU, 96, Color(1, 1, 1, 0.10 + ring_pulse), 2.0)
	draw_arc(base_position, 260.0, 0.0, TAU, 96, Color(1, 1, 1, 0.05 + ring_pulse * 0.4), 1.0)


func _draw_base() -> void:
	var base_color := BASE_COLOR if base_hp > BASE_MAX_HP * 0.3 else BASE_WARNING_COLOR
	var glow := 0.18 + 0.08 * (0.5 + 0.5 * sin(pulse_time * 4.0))
	draw_circle(base_position, base_radius, base_color)
	draw_circle(base_position, base_radius + 12.0, Color(base_color.r, base_color.g, base_color.b, glow))
	draw_arc(base_position, base_radius + 20.0, 0.0, TAU, 72, Color(base_color.r, base_color.g, base_color.b, 0.24), 3.0)


func _draw_turrets() -> void:
	for turret in turrets:
		var turret_color := Color("f4f1de") if not bool(turret["temporary"]) else Color("6fffe9")
		draw_circle(turret["position"], 14.0, turret_color)
		draw_circle(turret["position"], 18.0, Color(turret_color.r, turret_color.g, turret_color.b, 0.15))
		draw_line(turret["position"], turret["position"] + Vector2.UP * 16.0, turret_color, 4.0)


func _draw_bullets() -> void:
	for bullet in bullets:
		draw_circle(bullet["position"], float(bullet["radius"]), BULLET_COLOR)


func _draw_enemies() -> void:
	for enemy in enemies:
		draw_circle(enemy["position"], float(enemy["radius"]), enemy["color"])
		var bar_width := float(enemy["radius"]) * 2.0
		var hp_ratio := clamp(float(enemy["hp"]) / max(float(enemy["hp"]), 1.0), 0.0, 1.0)
		if ENEMY_LIBRARY.has(enemy["type"]):
			hp_ratio = clamp(float(enemy["hp"]) / float(ENEMY_LIBRARY[enemy["type"]]["hp"]), 0.0, 1.0)
		draw_rect(Rect2(enemy["position"] + Vector2(-bar_width * 0.5, -float(enemy["radius"]) - 10.0), Vector2(bar_width, 4.0)), Color(0, 0, 0, 0.4), true)
		draw_rect(Rect2(enemy["position"] + Vector2(-bar_width * 0.5, -float(enemy["radius"]) - 10.0), Vector2(bar_width * hp_ratio, 4.0)), Color("e0fbfc"), true)


func _update_ui() -> void:
	var live_status := "LIVE" if not game_over else "ROUND OVER"
	title_label.text = "CHAT DEFENSE"
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
		var t := float(i) / generator.mix_rate
		var envelope := 1.0 - (float(i) / max(frame_count, 1))
		var sample := sin(TAU * frequency * t) * amplitude * envelope
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
		var bytes := client.get_available_bytes()
		if bytes <= 0:
			continue
		var incoming := client.get_utf8_string(bytes)
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
