class_name DotQuerySnapshot
extends RefCounted

## What the server looks like from outside, at one moment.
## Both query protocols read only this, so a game contributes its state once and they cannot disagree.
## Sections are separate so a list refresh can ask for [code]info[/code] alone.

const SECTION_INFO := "info"
const SECTION_PLAYERS := "players"
const SECTION_RULES := "rules"
const SECTION_GAME := "game"
const SECTION_TEAMS := "teams"
const SECTION_ROTATION := "rotation"
const SECTION_PERF := "perf"
const SECTION_BUILD := "build"
const SECTION_STATS := "stats"
const SECTION_PLAYER_STATS := "player_stats"

const ALL_SECTIONS: Array[String] = [
	SECTION_INFO,
	SECTION_PLAYERS,
	SECTION_RULES,
	SECTION_GAME,
	SECTION_TEAMS,
	SECTION_ROTATION,
	SECTION_PERF,
	SECTION_BUILD,
	SECTION_STATS,
	SECTION_PLAYER_STATS,
]

## Sections excluded from the revision hash, however much they change.
## [code]perf[/code] differs on every rebuild and would defeat [code]if_rev[/code] polling.
const VOLATILE_SECTIONS: Array[String] = [SECTION_PERF]

## Monotonic revision, bumped only when the content changed; derived from [member etag], not a timer.
var rev: int = 0

## Hash of the content, which is what [member rev] is derived from.
var etag: String = ""

## Unix seconds this snapshot was built.
var built_at: int = 0

## Identity, counts, addresses. The section a server browser lists from.
var info: Dictionary = {}

## One entry per connected client. May be empty by policy.
var players: Array = []

## Server variables a querier is allowed to see.
var rules: Dictionary = {}

## Whatever the game contributes: round number, scores, teams, next map. Free-form on purpose.
var game: Dictionary = {}

## Sides and their sizes, when a team roster is present. Separate from [member game] so a browser can render it.
var teams: Dictionary = {}

## What is playing, what is next, and what the rotation holds.
var rotation: Dictionary = {}

## Server health: tick, frame time, memory, uptime. For operators and monitors; not in the revision hash.
var perf: Dictionary = {}

## Engine, addon and platform versions. Static for the life of the process.
var build: Dictionary = {}

## Declared statistics and their server-wide totals, filled by the dot-stats bridge when attached.
var stats: Dictionary = {}

## Per-player statistics for connected players. Off unless an operator enables it; never keyed by account id.
var player_stats: Array = []

## Sections that were cut short by a size or policy limit, reported so a short list is not silent.
var truncated: PackedStringArray = PackedStringArray()


func _init() -> void:
	built_at = int(Time.get_unix_time_from_system())


func section(name: String) -> Variant:
	match name:
		SECTION_INFO: return info
		SECTION_PLAYERS: return players
		SECTION_RULES: return rules
		SECTION_GAME: return game
		SECTION_TEAMS: return teams
		SECTION_ROTATION: return rotation
		SECTION_PERF: return perf
		SECTION_BUILD: return build
		SECTION_STATS: return stats
		SECTION_PLAYER_STATS: return player_stats
	return null


## Whether a section is excluded from the revision hash.
static func is_volatile(name: String) -> bool:
	return VOLATILE_SECTIONS.has(name)


func has_section(name: String) -> bool:
	return ALL_SECTIONS.has(name)


func mark_truncated(name: String) -> void:
	if not truncated.has(name):
		truncated.append(name)


## Convenience for providers: merge a dictionary into the game section.
func contribute_game(values: Dictionary) -> void:
	for key in values:
		game[key] = values[key]


func player_count() -> int:
	return int(info.get("players", 0))


func bot_count() -> int:
	return int(info.get("bots", 0))


## The DQP response body, carrying only the sections that were asked for.
## Unknown section names are reported in [code]unknown[/code], not ignored.
func to_dict(sections: PackedStringArray = PackedStringArray()) -> Dictionary:
	var wanted := sections
	if wanted.is_empty():
		wanted = PackedStringArray([SECTION_INFO])

	var out := {
		"rev": rev,
		"etag": etag,
		"ts": built_at,
		"sections": {},
	}

	var unknown := PackedStringArray()
	var body: Dictionary = out["sections"]

	for name in wanted:
		if not has_section(name):
			unknown.append(name)
			continue
		body[name] = section(name)

	if not unknown.is_empty():
		out["unknown"] = Array(unknown)

	if not truncated.is_empty():
		out["truncated"] = Array(truncated)

	return out


## The body sent when a querier already holds this revision.
func to_unchanged_dict() -> Dictionary:
	return {"rev": rev, "etag": etag, "ts": built_at, "unchanged": true}


## Everything, for `query_status` and for a bug report.
func to_full_dict() -> Dictionary:
	return to_dict(PackedStringArray(ALL_SECTIONS))


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("rev         %d (%s)" % [rev, etag.substr(0, 12)])
	out.append("built       %d seconds ago" % [
		int(Time.get_unix_time_from_system()) - built_at
	])
	out.append("name        %s" % str(info.get("name", "")))
	out.append("map         %s" % str(info.get("map", "")))
	out.append("players     %d/%d (%d bots, %d connecting)" % [
		int(info.get("players", 0)),
		int(info.get("max_players", 0)),
		int(info.get("bots", 0)),
		int(info.get("connecting", 0)),
	])
	out.append("listed      %d players, %d rules, %d game keys" % [
		players.size(), rules.size(), game.size()
	])

	var extra := PackedStringArray()
	for name in [
		SECTION_TEAMS, SECTION_ROTATION, SECTION_PERF,
		SECTION_BUILD, SECTION_STATS, SECTION_PLAYER_STATS,
	]:
		var value: Variant = section(name)
		var count := 0
		if typeof(value) == TYPE_DICTIONARY:
			count = (value as Dictionary).size()
		elif typeof(value) == TYPE_ARRAY:
			count = (value as Array).size()
		if count > 0:
			extra.append("%s(%d)" % [name, count])

	out.append("sections    %s" % (
		", ".join(Array(extra)) if not extra.is_empty() else "core only"
	))
	if not truncated.is_empty():
		out.append("truncated   %s" % ", ".join(Array(truncated)))
	return out
