@tool
class_name DotQueryStats
extends Node

## Publishes declared statistics through the query protocol, optionally.
##
## A server browser answers "who is playing". A tracker worth having answers "what
## happened here" — how many rounds this box has run, how many kills it has counted,
## what the people on it right now have done. dot-stats already holds all of that;
## this is the half that lets somebody ask for it from outside.
##
## [b]Nothing here names a [code]DotStats*[/code] identifier.[/b] dot-stats is
## optional and a script mentioning a [code]class_name[/code] the project does not
## have fails to parse — taking every script that references it down too, which for
## an addon in the query path means the server stops answering rather than stops
## reporting statistics. The tracker is reached duck-typed: an object with
## [code]players()[/code], [code]session_values()[/code] and a [code]schema[/code]
## is a tracker as far as this is concerned, so a game can also hand over something
## of its own with that shape.
##
## Three kinds of question, which is the split a querier actually wants:
##
## [b]server[/b] — what this box has done since it booted. Counted here, not by
## dot-stats, because it is not per-player and outlives every player on it.
##
## [b]game[/b] — the published stats totalled across everyone currently connected.
## An aggregate identifies nobody, so it is safe to publish and is on by default.
##
## [b]players[/b] — one row per connected player. [b]Off by default, and it takes
## more than a boolean to turn on.[/b] See [member player_key_format].

const CHANNEL := "query"
const SERVICE := &"dot_query_stats"

## Ceiling on rows in the player_stats section, independent of the player list's.
##
## Per-player statistics are many numbers per player where the player list is a
## handful of fields, so the same count is a much larger response.
const MAX_PLAYER_ROWS := 64

@export_group("Source")

## Where to find the statistics tracker. Duck-typed; dot-stats' tracker fits.
##
## Left unresolved, the stats sections are simply absent — which is what should
## happen on a server whose game does not count anything.
@export var tracker_ref: DotNodeRef = null

@export_group("What to publish")

## Publish the schema: every stat's id, display name, kind and unit.
##
## [b]On, because the numbers are illegible without it.[/b] A querier handed
## [code]{"top_speed": 412.8}[/code] cannot render it — units unknown, decimals
## unknown, and no idea whether a second reading should replace that or be added to
## it. The schema is small, static, and the difference between a number and a fact.
@export var publish_schema: bool = true

## Publish per-stat totals across the players currently connected.
##
## Safe by construction: a sum over everyone on the server identifies nobody, and
## it is the figure a "busiest server" listing actually wants.
@export var publish_totals: bool = true

## Publish one row of statistics per connected player.
##
## [b]Off, and a boolean is not enough to turn it on[/b] — see
## [member player_key_format]. A per-player stat line is a far more detailed
## record of a person than the name and score A2S publishes, and an operator
## should have to mean it.
@export var publish_players: bool = false

@export_group("Identity")

## How a connected session's userid becomes the key its statistics were filed under.
##
## [b]This is the join that cannot be guessed, and the reason
## [member publish_players] needs a second setting to work.[/b] A game chooses its
## own key: this family's games use [code]arena-player-%08d[/code], a bare userid,
## and a per-account string, and nothing in dot-stats records which. Getting it
## wrong does not throw — it matches no player and publishes an empty section,
## which reads as "nobody has done anything" rather than as a misconfiguration.
##
## A printf format taking one integer, the session's [code]userid[/code]. Empty
## refuses to publish player rows however [member publish_players] is set.
##
## [b]The key itself is never published.[/b] It is matched against and discarded;
## rows carry the display name and userid the player list already carries. A game
## keying statistics by account uid would otherwise publish that uid to anyone who
## sends a datagram, and dot-user's whole point is that an operator cannot
## correlate players across servers — undoing it from the query side would be no
## better than undoing it from the login side.
@export var player_key_format: String = ""

## An object that maps a session to its statistics key itself, when no format can.
##
## Duck-typed: anything with [code]_query_stats_key(session) -> String[/code].
## Wins over [member player_key_format] when both are set. For a game whose key
## depends on something other than the userid — an account id it holds elsewhere,
## or a per-round identity.
@export var resolver_ref: DotNodeRef = null

var server: DotServer = null

var _tracker: Object = null
var _resolver: Object = null

## Server-level counters, which nothing else holds.
var _sessions_seen: int = 0
var _queries_answered: int = 0


func setup(p_server: DotServer) -> void:
	server = p_server
	DotRegistry.register(SERVICE, self)

	# resolve_or_null rather than resolve: both of these are optional, and a
	# missing one must leave the section absent rather than log an error that
	# reads as a broken query listener.
	if tracker_ref != null:
		_tracker = tracker_ref.resolve_or_null(self, CHANNEL)
	if resolver_ref != null:
		_resolver = resolver_ref.resolve_or_null(self, CHANNEL)

	if _tracker != null and not _looks_like_tracker(_tracker):
		DotLog.warn(
			CHANNEL,
			"the query stats tracker has the wrong shape and is ignored",
			{"got": _tracker.get_class()}
		)
		_tracker = null

	if publish_players and player_key_format == "" and _resolver == null:
		# Named at boot rather than left to produce an empty section. An operator
		# who ticked publish_players and got nothing would reasonably conclude the
		# bridge is broken; it is doing exactly what it was told.
		DotLog.warn(
			CHANNEL,
			"publish_players is on but no player_key_format or resolver is set: "
			+ "no player statistics will be published",
			{"setting": "player_key_format"}
		)


func _exit_tree() -> void:
	DotRegistry.unregister_instance(SERVICE, self)


## Points the bridge at a tracker directly, for a game that has one in hand.
func attach(tracker: Object) -> DotResult:
	if tracker != null and not _looks_like_tracker(tracker):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"That is not a statistics tracker.",
			"needs players() and session_values(); got a %s" % tracker.get_class()
		)
	_tracker = tracker
	return DotResult.success(tracker)


func has_tracker() -> bool:
	return _tracker != null and is_instance_valid(_tracker)


# --- Counters --------------------------------------------------------------

func note_session() -> void:
	_sessions_seen += 1


func note_query() -> void:
	_queries_answered += 1


# --- Sections --------------------------------------------------------------

## Builds the [code]stats[/code] section: schema, server counters and game totals.
func build_stats(snapshot: DotQuerySnapshot) -> Dictionary:
	var out := {"server": _server_stats()}

	if not has_tracker():
		return out

	if publish_schema:
		out["schema"] = _schema_rows()

	if publish_totals:
		out["game"] = _totals(snapshot)

	return out


## Builds the [code]player_stats[/code] section. Empty unless fully configured.
func build_player_stats(snapshot: DotQuerySnapshot) -> Array:
	if not publish_players or not has_tracker() or server == null:
		return []
	if player_key_format == "" and _resolver == null:
		return []

	var out: Array = []

	for session in server.playing_sessions():
		if out.size() >= MAX_PLAYER_ROWS:
			snapshot.mark_truncated(DotQuerySnapshot.SECTION_PLAYER_STATS)
			break

		var key := _key_for(session)
		if key == "":
			continue

		var values := _values_for(key)
		if values.is_empty():
			continue

		out.append({
			"name": session.display_name,
			"userid": session.userid,
			"values": values,
		})

	return out


func _server_stats() -> Dictionary:
	return {
		"uptime": server.uptime_seconds() if server != null else 0,
		"sessions_seen": _sessions_seen,
		"queries_answered": _queries_answered,
		"players_now": server.player_count() if server != null else 0,
	}


## The published half of the schema, as rows a querier can render.
##
## Only stats flagged for publication appear. dot-stats already draws that line for
## the backbone report and it is the right line here: a stat a game keeps private
## from its own backend has no business going out over UDP.
func _schema_rows() -> Array:
	var out: Array = []

	var schema: Object = _tracker.get("schema")
	if schema == null or not schema.has_method("published"):
		return out

	for def in schema.call("published"):
		if def == null:
			continue
		var row := {"id": str(def.get("id"))}
		var display := str(def.get("display_name"))
		if display != "":
			row["name"] = display
		var unit := str(def.get("unit"))
		if unit != "":
			row["unit"] = unit
		if def.has_method("kind_name"):
			row["kind"] = str(def.call("kind_name"))
		row["decimals"] = int(def.get("decimals"))
		out.append(row)

	return out


## Every published stat, summed across the players the tracker is holding.
func _totals(snapshot: DotQuerySnapshot) -> Dictionary:
	var out := {}

	var ids := _published_ids()
	if ids.is_empty():
		return out

	var counted := 0

	for key in _tracker.call("players"):
		if counted >= MAX_PLAYER_ROWS * 4:
			# A tracker holds players who have left until the next report, so this
			# walk is not bounded by the player list. Capped, and said so, rather
			# than letting a long-running server turn every query into a long walk.
			snapshot.mark_truncated(DotQuerySnapshot.SECTION_STATS)
			break
		counted += 1

		var values := _values_for(str(key))
		for id in ids:
			if values.has(id):
				out[id] = float(out.get(id, 0.0)) + float(values[id])

	return out


func _published_ids() -> PackedStringArray:
	var out := PackedStringArray()

	var schema: Object = _tracker.get("schema")
	if schema == null or not schema.has_method("published"):
		return out

	for def in schema.call("published"):
		if def != null:
			out.append(str(def.get("id")))

	return out


## One player's published values, keyed by stat id.
func _values_for(key: String) -> Dictionary:
	if not _tracker.has_method("session_values"):
		return {}

	var values: Object = _tracker.call("session_values", StringName(key))
	if values == null or not values.has_method("to_dictionary"):
		return {}

	var raw: Dictionary = values.call("to_dictionary")

	# to_dictionary() carries whatever the tracker holds, published or not. The
	# published set is the filter, applied here rather than trusted upstream: a
	# stat marked private is private on this path too.
	var allowed := _published_ids()
	var out := {}
	for id in allowed:
		if raw.has(id):
			out[id] = raw[id]

	return out


func _key_for(session: DotClientSession) -> String:
	if _resolver != null and is_instance_valid(_resolver) \
			and _resolver.has_method("_query_stats_key"):
		return str(_resolver.call("_query_stats_key", session))

	if player_key_format == "":
		return ""

	return player_key_format % session.userid


static func _looks_like_tracker(candidate: Object) -> bool:
	return candidate.has_method("players") and candidate.has_method("session_values")


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"tracker": has_tracker(),
		"schema": publish_schema,
		"totals": publish_totals,
		"players": publish_players and (player_key_format != "" or _resolver != null),
		"sessions_seen": _sessions_seen,
		"queries_answered": _queries_answered,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("tracker     %s" % ("attached" if has_tracker() else "none"))
	out.append("schema      %s" % ("published" if publish_schema else "withheld"))
	out.append("totals      %s" % ("published" if publish_totals else "withheld"))

	if not publish_players:
		out.append("players     withheld")
	elif player_key_format == "" and _resolver == null:
		out.append("players     ON, but no key format or resolver: nothing published")
	else:
		out.append("players     published (%s)" % (
			"resolver" if _resolver != null else player_key_format
		))

	out.append("seen        %d sessions, %d queries" % [
		_sessions_seen, _queries_answered
	])
	return out
