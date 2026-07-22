class_name WorldData
extends RefCounted
## Typed view of the wire protocol's world document (schema in
## m1-shared-context.md), parsed once at welcome (network_client.gd) so the
## rest of the client never touches raw JSON dictionaries.
##
## Rail math mirrors `world.gleam` / `harness/test_m1_flight.py`'s
## `station_rail_position` exactly:
##   angle(t) = phase * TAU + TAU * t / period_s
##   position(t) = parent_position(t) + radius * (cos(angle), sin(angle))
## Parents chain station -> planet -> star; the star (orbit null) is fixed
## at the origin.


## Circular rail around a parent body.
class Orbit:
	var radius: float
	var period_s: float
	var phase: float

	static func from_dict(data: Dictionary) -> Orbit:
		var orbit := Orbit.new()
		orbit.radius = float(data.get("radius", 0.0))
		orbit.period_s = float(data.get("period_s", 1.0))
		orbit.phase = float(data.get("phase", 0.0))
		return orbit

	## Rail position at sim time `at_t`, given the parent's position then.
	func position_at(parent_pos: Vector2, at_t: float) -> Vector2:
		var angle := phase * TAU + TAU * at_t / period_s
		return parent_pos + Vector2(cos(angle), sin(angle)) * radius


## A celestial body: the star (no orbit, fixed at the origin) or a planet
## on a rail around its parent.
class Body:
	var id: String
	var kind: String  ## "star" | "planet"
	var radius: float  ## physical radius, world units
	var parent_id: String  ## "" for the star
	var orbit: Orbit  ## null for the star

	static func from_dict(data: Dictionary) -> Body:
		var body := Body.new()
		body.id = str(data.get("id", ""))
		body.kind = str(data.get("kind", ""))
		body.radius = float(data.get("radius", 0.0))
		var parent: Variant = data.get("parent")
		body.parent_id = "" if parent == null else str(parent)
		var orbit: Variant = data.get("orbit")
		body.orbit = Orbit.from_dict(orbit) if orbit is Dictionary else null
		return body


## A station docking port, derived server-side from a `Q` glyph in the
## concourse (wire: the station's `berths`, issue #31). `tile` is the
## interior/composite berth tile; `orientation` is the port's outward normal in
## world degrees (y-up, 0 = +x/east). The moored hull's heading derives from
## these (#14); its exterior pose is drawn at the station sprite's own "berth"
## anchor (see world_view.gd), not from any wire anchor. Accepts the object form
## `{tile, orientation?}` and a bare `[x, y]` array.
class Berth:
	const DEFAULT_ORIENTATION := 90.0  ## degrees, north; server default

	var tile: Vector2i
	var orientation: float = DEFAULT_ORIENTATION

	static func from_variant(data: Variant) -> Berth:
		var berth := Berth.new()
		if data is Array and data.size() >= 2:
			berth.tile = Vector2i(int(data[0]), int(data[1]))
		elif data is Dictionary:
			var tile: Variant = data.get("tile", [0, 0])
			if tile is Array and tile.size() >= 2:
				berth.tile = Vector2i(int(tile[0]), int(tile[1]))
			berth.orientation = float(data.get("orientation", DEFAULT_ORIENTATION))
		return berth


## A dockable station on a rail around its parent body.
class Station:
	var id: String
	var name: String
	var parent_id: String
	var dock_radius: float
	var orbit: Orbit
	var crane: bool = false
	## Walkable concourse interior (same shape as a ship deck plan), or
	## null when this station has none. Parsed with ShipClassData — id and
	## name are absent on concourses, so they are backfilled from the
	## station for display.
	var concourse: ShipClassData = null
	## Authored docking ports (may be empty). Carries the port orientation so
	## the client can derive mooring alignment from data rather than assuming
	## side-on (#14).
	var berths: Array[Berth] = []

	static func from_dict(data: Dictionary) -> Station:
		var station := Station.new()
		station.id = str(data.get("id", ""))
		station.name = str(data.get("name", station.id))
		station.parent_id = str(data.get("parent", ""))
		station.dock_radius = float(data.get("dock_radius", 0.0))
		var orbit: Variant = data.get("orbit")
		station.orbit = Orbit.from_dict(orbit) if orbit is Dictionary else null
		station.crane = bool(data.get("crane", false))
		var concourse: Variant = data.get("concourse")
		if concourse is Dictionary:
			station.concourse = ShipClassData.from_dict(concourse)
			station.concourse.id = station.id
			station.concourse.name = station.name
		for berth_data: Variant in data.get("berths", []):
			station.berths.append(Berth.from_variant(berth_data))
		return station


var bodies: Array[Body] = []
var stations: Array[Station] = []
var spawn_station: String = ""


static func from_dict(data: Dictionary) -> WorldData:
	var world := WorldData.new()
	for body_data: Variant in data.get("bodies", []):
		if body_data is Dictionary:
			world.bodies.append(Body.from_dict(body_data))
	for station_data: Variant in data.get("stations", []):
		if station_data is Dictionary:
			world.stations.append(Station.from_dict(station_data))
	world.spawn_station = str(data.get("spawn_station", ""))
	return world


func find_body(body_id: String) -> Body:
	for body in bodies:
		if body.id == body_id:
			return body
	return null


func find_station(station_id: String) -> Station:
	for station in stations:
		if station.id == station_id:
			return station
	return null


## Display name for a station id, falling back to the id itself.
func station_name(station_id: String) -> String:
	var station := find_station(station_id)
	return station_id if station == null else station.name


## Rail position of a body at sim time `at_t`, chaining through its parent.
## Matches `world.body_position` in world.gleam.
func body_position(body_id: String, at_t: float) -> Vector2:
	var body := find_body(body_id)
	if body == null or body.orbit == null:
		return Vector2.ZERO
	var parent_pos := Vector2.ZERO
	if body.parent_id != "":
		parent_pos = body_position(body.parent_id, at_t)
	return body.orbit.position_at(parent_pos, at_t)


## Rail position of a station at sim time `at_t`, chaining through its
## parent body. Matches `world.station_position` in world.gleam.
func station_position(station_id: String, at_t: float) -> Vector2:
	var station := find_station(station_id)
	if station == null or station.orbit == null:
		return Vector2.ZERO
	return station.orbit.position_at(body_position(station.parent_id, at_t), at_t)
