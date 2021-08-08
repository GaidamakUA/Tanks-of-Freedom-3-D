extends Spatial

const RETALIATION_DELAY = 0.1

onready var map = $"map"
onready var ui = $"ui"

onready var audio = $"/root/SimpleAudioLibrary"
onready var switcher = $"/root/SceneSwitcher"
onready var match_setup = $"/root/MatchSetup"
onready var settings = $"/root/Settings"
onready var campaign = $"/root/Campaign"

var state = preload("res://scenes/board/logic/state.gd").new()
var radial_abilities = preload("res://scenes/board/logic/radial_abilities.gd").new()
var abilities = preload("res://scenes/abilities/abilities.gd").new(self)
var events = preload("res://scenes/board/logic/events.gd").new()
var observers = preload("res://scenes/board/logic/observers/observers.gd").new(self)
var scripting = preload("res://scenes/board/logic/scripting.gd").new()
var ai = preload("res://scenes/board/logic/ai/ai.gd").new(self)
var collateral = preload("res://scenes/board/logic/collateral.gd").new(self)


var selected_tile = null
var active_ability = null
var last_hover_tile = null
onready var selected_tile_marker = $"marker_anchor/tile_marker"
onready var movement_markers = $"marker_anchor/movement_markers"
onready var interaction_markers = $"marker_anchor/interaction_markers"
onready var path_markers = $"marker_anchor/path_markers"
onready var ability_markers = $"marker_anchor/ability_markers"
onready var explosion_anchor = $"marker_anchor"
onready var explosion = $"marker_anchor/explosion"

var explosion_template = preload("res://scenes/fx/explosion.tscn")
var projectile_template = preload("res://scenes/fx/projectile.tscn")

var ending_turn_in_progress = false
var initial_hq_cam_skipped = false
var mouse_click_position = null

func _ready():
    self.set_up_map()
    self.set_up_board()
    self.start_turn()

func _input(event):
    if not self.ui.is_panel_open():
        if not self.state.is_current_player_ai():
            if event.is_action_pressed("ui_accept"):
                self.select_tile(self.map.tile_box_position)

            if event.is_action_pressed("ui_cancel"):
                self.unselect_action()

            if event.is_action_pressed("end_turn"):
                self.start_ending_turn()
            elif event.is_action_released("end_turn"):
                self.abort_ending_turn()

            if event.is_action_pressed("mouse_click"):
                self.mouse_click_position = event.position
            if event.is_action_released("mouse_click"):
                if self.mouse_click_position != null and event.position.distance_squared_to(self.mouse_click_position) < self.map.camera.MOUSE_MOVE_THRESHOLD:
                    self.select_tile(self.map.tile_box_position)
                self.mouse_click_position = null

        if event.is_action_pressed("editor_menu"):
            self.toggle_radial_menu()
    else:
        if self.ui.radial.is_visible() and not self.ui.is_popup_open():
            if event.is_action_pressed("ui_cancel"):
                self.toggle_radial_menu()

            if event.is_action_pressed("editor_menu"):
                self.toggle_radial_menu()

func _physics_process(_delta):
    self.hover_tile()

func hover_tile():
    if not self.ui.is_panel_open():
        var tile = self.map.model.get_tile(self.map.tile_box_position)

        if tile != self.last_hover_tile:
            self.last_hover_tile = tile

            self.update_tile_highlight(tile)

            self.path_markers.reset()
            if self.should_draw_move_path(tile):
                var path = self.movement_markers.get_path_to_tile(tile)
                self.path_markers.draw_path(path)


func set_up_map():
    if self.match_setup.campaign_name != null:
        self.load_campaign_map()
    else:
        self.load_skirmish_map()

func set_up_board():
    self.audio.track("soundtrack_1")
    self.scripting.ingest_scripts(self, self.map.model.scripts)
    self.setup_radial_menu()

    var index = 0
    for player_setup in self.match_setup.setup:
        if player_setup["side"] != self.map.templates.PLAYER_NEUTRAL:
            self.state.add_player(player_setup["type"], player_setup["side"])
            self.state.add_player_ap(index, player_setup["ap"])
            index += 1

    self.state.register_heroes(self.map.model)


func end_turn():
    if self.ui.radial.is_visible():
        self.toggle_radial_menu()
    self.unselect_tile()
    #self.remove_unit_hightlights()
    self.state.switch_to_next_player()
    self.call_deferred("start_turn")

func start_turn():
    self.update_for_current_player()

    if self.state.is_current_player_ai():
        if not self.ui.cinematic_bars.is_extended:
            self.ui.show_cinematic_bars()
            yield(self.get_tree().create_timer(0.25), "timeout")
    else:
        if self.ui.cinematic_bars.is_extended:
            self.ui.hide_cinematic_bars()

    if self._should_perform_hq_cam():
        if self._move_camera_to_hq():
            yield(self.get_tree().create_timer(1), "timeout")

    self.replenish_unit_actions()
    self.gain_building_ap()
    self.ui.update_resource_value(self.state.get_current_ap())
    self.ui.flash_start_end_card(self.state.get_current_side(), self.state.turn)

    if self.state.is_current_player_ai():
        self.map.camera.ai_operated = true
        self.map.hide_tile_box()
        self.ai.run()
    else:
        self.map.camera.ai_operated = false
        self.map.show_tile_box()

    self.events.emit_turn_started(self.state.turn, self.state.current_player)


func select_tile(position):
    if self.map.camera.camera_in_transit or self.map.camera.script_operated:
        return

    var tile = self.map.model.get_tile(position)
    if tile == null:
        return

    var current_player = self.state.get_current_player()
    var open_unit_abilities = false

    if self.active_ability != null:
        if self.ability_markers.marker_exists(position):
            self.execute_active_ability(tile)
        else:
            self.unselect_tile()

    elif tile.is_selectable(current_player["side"]):
        if self.selected_tile == tile:
            open_unit_abilities = true
        self.selected_tile = tile
        self.show_contextual_select(open_unit_abilities)

    elif self.selected_tile != null:
        if self.selected_tile.unit.is_present():
            if self.can_move_to_tile(tile):
                self.move_unit(self.selected_tile, tile)
                self.selected_tile = tile
                self.show_contextual_select()

            elif self.selected_tile.is_neighbour(tile) && tile.can_unit_interact(self.selected_tile.unit.tile) && self.state.can_current_player_afford(1):
                self.handle_interaction(tile)

            else:
                self.unselect_tile()

        else:
            self.unselect_tile()

    self.update_tile_highlight(tile)

    if self.selected_tile != null:
        self.audio.play("menu_click")


func unselect_action():
    if self.active_ability != null:
        self.cancel_ability()
    else:
        self.unselect_tile()


func unselect_tile():
    self.reset_unit_markers()
    self.cancel_ability()
    self.selected_tile = null
    self.selected_tile_marker.hide()

func reset_unit_markers():
    self.movement_markers.reset()
    self.interaction_markers.reset()
    self.path_markers.reset()

func cancel_ability():
    self.active_ability = null
    self.ability_markers.reset()


func load_skirmish_map():
    self.map.loader.load_map_file(self.match_setup.map_name)

func load_campaign_map():
    self.map.loader.load_campaign_map(self.match_setup.campaign_name, self.match_setup.mission_no)
    self.match_setup.campaign_win = true


func update_for_current_player():
    var current_player = self.state.get_current_player()

    self.map.set_tile_box_side(current_player["side"])

func toggle_radial_menu(context_object=null):
    if self.radial_abilities.is_object_without_abilities(self, context_object):
        return

    if not self.ui.is_radial_open():
        self.setup_radial_menu(context_object)
    else:
        self.map.camera.force_stick_reset()

    # this might look odd, but is_visible does not change until the next frame after show/hide
    if not self.map.camera.ai_operated:
        if self.ui.radial.is_visible() and not self.state.is_current_player_ai():
            self.map.camera.paused = false
        elif not self.ui.radial.is_visible():
            self.map.camera.paused = true

    if self.ui.radial.is_visible():
        self.ai._ai_paused = false
    elif not self.ui.radial.is_visible():
        self.ai._ai_paused = true

    self.ui.toggle_radial()

    self.map.tile_box.set_visible(not self.map.tile_box.is_visible())

func setup_radial_menu(context_object=null):
    self.ui.radial.clear_fields()
    if context_object == null:
        self.ui.radial.set_field(self.ui.icons.disk.instance(), "Save/Load game", 2)
        self.ui.radial.set_field(self.ui.icons.back.instance(), "Main menu", 6, self, "main_menu")
    else:
        self.radial_abilities.fill_radial_with_abilities(self, self.ui.radial, context_object)


func place_selection_marker():
    self.selected_tile_marker.show()
    var new_position = self.selected_tile_marker.get_translation()
    var placement = self.map.map_to_world(self.selected_tile.position)
    placement.y = new_position.y
    self.selected_tile_marker.set_translation(placement)

func show_unit_movement_markers():
    self.movement_markers.show_unit_movement_markers_for_tile(self.selected_tile, self.state.get_current_ap())

func show_unit_interaction_markers():
    self.interaction_markers.show_interaction_markers_for_tile(self.selected_tile, self.state.get_current_ap())

func show_contextual_select(open_unit_abilities=false):
    self.place_selection_marker()
    self.movement_markers.reset()
    self.path_markers.reset()

    if self.selected_tile.unit.is_present():
        self.show_unit_movement_markers()
        self.show_unit_interaction_markers()
        if open_unit_abilities and self.selected_tile.unit.tile.has_active_ability():
            self.toggle_radial_menu(self.selected_tile.unit.tile)
    if self.selected_tile.building.is_present():
        self.toggle_radial_menu(self.selected_tile.building.tile)

func move_unit(source_tile, destination_tile):
    var move_cost = self.movement_markers.get_tile_cost(destination_tile)
    destination_tile.unit.set_tile(source_tile.unit.tile)
    source_tile.unit.release()
    self.use_current_player_ap(move_cost)
    destination_tile.unit.tile.use_move(move_cost)

    self.reset_unit_position(source_tile, destination_tile.unit.tile)
    self.update_unit_position(destination_tile)

    self.events.emit_unit_moved(destination_tile.unit.tile, source_tile, destination_tile)

func update_unit_position(tile):
    var path = self.movement_markers.get_path_to_tile(tile)
    var movement_path = self.path_markers.convert_path_to_directions(path)
    var unit = tile.unit.tile

    unit.animate_path(movement_path)

func reset_unit_position(tile, unit):
    unit.stop_animations()
    var world_position = self.map.map_to_world(tile.position)
    var old_position = unit.get_translation()
    world_position.y = old_position.y
    unit.set_translation(world_position)

func can_move_to_tile(tile):
    var move_cost = self.movement_markers.get_tile_cost(tile)
    if move_cost != null and move_cost > 0 and tile.can_acommodate_unit():
        return true
    return false

func should_draw_move_path(tile):
    if self.selected_tile != null:
        if self.selected_tile.unit.is_present():
            if self.can_move_to_tile(tile):
                return true
    return false

func handle_interaction(tile):
    if self.selected_tile != null:
        if self.selected_tile.unit.is_present():
            if tile.unit.is_present():
                self.battle(self.selected_tile, tile)
                self.use_current_player_ap(1)
                if self.selected_tile != null && self.selected_tile.unit.is_present():
                    self.show_contextual_select()
            if tile.building.is_present():
                self.capture(self.selected_tile, tile)
                self.use_current_player_ap(1)
                if self.selected_tile != null && self.selected_tile.unit.is_present():
                    self.show_contextual_select()



func battle(attacker_tile, defender_tile):
    var attacker = attacker_tile.unit.tile
    var defender = defender_tile.unit.tile

    attacker.use_move(1)
    attacker.use_attack()

    attacker.rotate_unit_to_direction(attacker_tile.get_direction_to_neighbour(defender_tile))

    defender.receive_damage(attacker.get_attack())
    attacker.sfx_effect("attack")

    if defender.is_alive():
        defender.show_explosion()
        defender.sfx_effect("damage")

        if defender.can_attack(attacker) && defender.has_moves():
            defender.use_all_moves()
            attacker.receive_damage(defender.get_attack())

            if attacker.is_alive():
                yield(self.get_tree().create_timer(self.RETALIATION_DELAY), "timeout")
                defender.rotate_unit_to_direction(defender_tile.get_direction_to_neighbour(attacker_tile))
                defender.sfx_effect("attack")
                attacker.show_explosion()
                attacker.sfx_effect("damage")

                self.events.emit_unit_attacked(defender, attacker)
            else:
                var attacker_id = attacker.get_instance_id()
                var attacker_type = attacker.template_name
                var attacker_side = attacker.side

                self.unselect_tile()
                self.destroy_unit_on_tile(attacker_tile)
                self.events.emit_unit_destroyed(defender, attacker_id, attacker_type, attacker_side)

        self.events.emit_unit_attacked(attacker, defender)
    else:
        var defender_id = defender.get_instance_id()
        var defender_type = defender.template_name
        var defender_side = defender.side

        self.destroy_unit_on_tile(defender_tile)
        self.events.emit_unit_destroyed(attacker, defender_id, defender_type, defender_side)

func destroy_unit_on_tile(tile, skip_explosion=false):
    if tile.unit.tile.unit_class == "hero":
        self.state.clear_hero_for_side(tile.unit.tile.side)

    if not skip_explosion:
        self.explode_a_tile(tile, true)
        self.collateral.generate_collateral(tile)
        self.collateral.damage_tile(tile)

        if self.settings.get_option("cam_shake"):
            self.map.camera.shake()
    tile.unit.clear()

func explode_a_tile(tile, grab_sfx=false):
    var new_explosion = self._spawn_temporary_explosion_instance_on_tile(tile, 0.5)
    new_explosion.explode()
    if grab_sfx:
        new_explosion.grab_sfx_effect(tile.unit.tile)

func smoke_a_tile(tile):
    var new_explosion = self._spawn_temporary_explosion_instance_on_tile(tile, 0.5)
    new_explosion.puff_some_smoke()

func bless_a_tile(tile):
    var new_explosion = self._spawn_temporary_explosion_instance_on_tile(tile, 1.0)
    new_explosion.rain_bless()

func heal_a_tile(tile):
    var new_explosion = self._spawn_temporary_explosion_instance_on_tile(tile, 1.0)
    new_explosion.rain_heal()

func _spawn_temporary_explosion_instance_on_tile(tile, free_delay=1.5):
    var position = self.map.map_to_world(tile.position)
    var new_explosion = self.explosion_template.instance()
    self.explosion_anchor.add_child(new_explosion)
    new_explosion.set_translation(Vector3(position.x, 0, position.z))
    self.destroy_explosion_with_delay(new_explosion, free_delay)

    return new_explosion

func capture(attacker_tile, building_tile):
    var attacker = attacker_tile.unit.tile
    var building = building_tile.building.tile

    var old_side = building.side

    attacker.use_all_moves()
    self.map.builder.set_building_side(building_tile.position, attacker.side)
    self.smoke_a_tile(building_tile)
    building.sfx_effect("capture")

    if building.require_crew and not self.abilities.can_intimidate_crew(attacker):
        yield(self.get_tree().create_timer(self.RETALIATION_DELAY), "timeout")
        self.smoke_a_tile(attacker_tile)
        attacker_tile.unit.clear()
        self.unselect_tile()

    self.events.emit_building_captured(building, old_side, attacker.side)

func activate_production_ability(args):
    self.toggle_radial_menu()

    var ability = args[0]

    var cost = ability.ap_cost
    cost = self.abilities.get_modified_cost(cost, ability.template_name, ability.source)

    if self.state.can_current_player_afford(cost):
        self.active_ability = ability
        self.ability_markers.show_ability_markers_for_tile(ability, self.selected_tile)

func activate_ability(args):
    var ability = args[0]
    if self.state.can_current_player_afford(ability.ap_cost) and not ability.is_on_cooldown():
        self.toggle_radial_menu()
        self.reset_unit_markers()
        self.active_ability = ability
        self.ability_markers.show_ability_markers_for_tile(ability, self.selected_tile)
        ability.active_source_tile = self.selected_tile

func execute_active_ability(tile):
    self.abilities.execute_ability(self.active_ability, tile)
    self.cancel_ability()



func remove_unit_hightlights():
    var current_player = self.state.get_current_player()
    var units = self.map.model.get_player_units(current_player["side"])

    for unit in units:
        unit.remove_highlight()

func replenish_unit_actions():
    var current_player = self.state.get_current_player()
    var units = self.map.model.get_player_units(current_player["side"])

    for unit in units:
        unit.clear_modifiers()
        self.abilities.apply_passive_modifiers(unit)
        unit.replenish_moves()
        unit.ability_cd_tick_down()

func gain_building_ap():
    var ap_sum = 0
    var current_player = self.state.get_current_player()
    var buildings = self.map.model.get_player_buildings(current_player["side"])

    for building in buildings:
        ap_sum += self.abilities.get_modified_ap_gain(building.ap_gain, building)
        if building.ap_gain > 0:
            building.animate_coin()

    self.add_current_player_ap(ap_sum)

func add_current_player_ap(ap_sum):
    self.state.add_current_player_ap(ap_sum)
    self.ui.update_resource_value(self.state.get_current_ap())

func use_current_player_ap(value):
    self.state.use_current_player_ap(value)
    self.ui.update_resource_value(self.state.get_current_ap())


func update_tile_highlight(tile):
    if not tile.building.is_present() and not tile.unit.is_present():
        self.ui.clear_tile_highlight()
        return

    var template_name
    var new_side
    var material_type = self.map.templates.MATERIAL_NORMAL

    if tile.building.is_present():
        template_name = tile.building.tile.template_name
        new_side = tile.building.tile.side
    if tile.unit.is_present():
        if tile.unit.tile.uses_metallic_material:
            material_type = self.map.templates.MATERIAL_METALLIC
        template_name = tile.unit.tile.template_name
        new_side = tile.unit.tile.side

    var new_tile = self.map.templates.get_template(template_name)
    new_tile.set_side_material(self.map.templates.get_side_material(new_side, material_type))

    self.ui.update_tile_highlight(new_tile)

    if tile.building.is_present():
        var ap_gain = tile.building.tile.ap_gain
        ap_gain = self.abilities.get_modified_ap_gain(ap_gain, tile.building.tile)
        self.ui.update_tile_highlight_building_panel(ap_gain)
    if tile.unit.is_present():
        self.ui.update_tile_highlight_unit_panel(tile.unit.tile)

func end_game(winner):
    self.map.camera.paused = true
    self.ai.abort()
    self.ui.hide_resource()
    self.ui.clear_tile_highlight()
    self._signal_winner(winner)
    self.ui.show_summary(winner)

func start_ending_turn():
    var step_delay = 0.1
    var step_value = 2
    var step_max = 30
    self.ending_turn_in_progress = true
    self.ui.show_end_turn()

    var index = 0

    while index * step_value <= step_max and self.ending_turn_in_progress:
        self.ui.update_end_turn_progress(index * step_value)
        yield(self.get_tree().create_timer(step_delay), "timeout")
        index += 1

    if self.ending_turn_in_progress:
        self.abort_ending_turn()
        self.call_deferred("end_turn")

func abort_ending_turn():
    self.ending_turn_in_progress = false
    self.ui.hide_end_turn()

func main_menu():
    self.ai.abort()
    self.switcher.main_menu()

func destroy_explosion_with_delay(explosion_object, delay):
    yield(self.get_tree().create_timer(delay), "timeout")
    explosion_object.queue_free()

func _signal_winner(winning_side):
    if self.state.is_player_human(winning_side):
        self.campaign.update_campaign_progress(self.match_setup.campaign_name, self.match_setup.mission_no)

func shoot_projectile(source_tile, destination_tile, tween_time=0.5):
    var new_projectile = self._spawn_temporary_projectile_instance_on_tile(source_tile)
    var position = self.map.map_to_world(destination_tile.position)
    new_projectile.shoot_at_position(Vector3(position.x, 0, position.z), tween_time)

func lob_projectile(source_tile, destination_tile, tween_time=0.5):
    var new_projectile = self._spawn_temporary_projectile_instance_on_tile(source_tile)
    var position = self.map.map_to_world(destination_tile.position)
    new_projectile.lob_at_position(Vector3(position.x, 0, position.z), tween_time)

func _spawn_temporary_projectile_instance_on_tile(tile):
    var position = self.map.map_to_world(tile.position)
    var new_projectile = self.projectile_template.instance()
    self.explosion_anchor.add_child(new_projectile)
    new_projectile.set_translation(Vector3(position.x, 0, position.z))

    return new_projectile

func _move_camera_to_hq():
    var hq_position = self.map.model.get_player_bunker_position(self.state.get_current_side())

    if hq_position != null:
        self.map.move_camera_to_position(hq_position)
        return true

    return false


func _should_perform_hq_cam():
    if not self.state.is_current_player_ai() and self.settings.get_option("hq_cam"):
        if self.map.model.metadata.has("skip_initial_hq_cam") and not self.initial_hq_cam_skipped:
            self.initial_hq_cam_skipped = true
            return false
        return true
    return false
