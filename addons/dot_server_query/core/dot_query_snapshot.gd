class_name DotQuerySnapshot
extends RefCounted

## What the server looks like from outside, at one moment.
##
## Both query protocols read this and nothing else. A2S flattens it into its fixed
## byte layout and loses most of it; DQP serialises it as-is. That is deliberate:
## a game contributes its state once, and both listeners — and anything else that
## wants server state, like the backbone stats report — see the same numbers. Two
## code paths gathering the same facts is two code paths that disagree the first
## time one is changed.
##
## Sections are separate because a querier wants different ones at different times.
## A server browser refreshing a list wants [code]info[/code] alone, twenty times a
## second across a thousand servers; a player looking at one server wants
## [code]players[/code] too. A2S has the same split and it is the right one.

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
##
## [b]This is what keeps conditional polling worth having.[/b] [code]perf[/code]
## carries a frame time and a memory figure that differ on every rebuild, so
## hashing it would mint a new revision every second and [code]if_rev[/code] would
## never once save a byte — the same trap [code]info.uptime[/code] falls into,
## and the reason uptime is erased before hashing too. A querier that wants
## live performance figures is asking every second anyway and is not the one
## conditional polling exists for.
const VOLATILE_SECTIONS: Array[String] = [SECTION_PERF]

## Monotonic revision, bumped only when the content actually changed.
##
## What makes conditional polling work: a tracker sends the revision it holds and
## a server that has not changed replies with a few dozen bytes instead of a few
## kilobytes. Derived from [member etag] rather than from a timer, so a server
## sitting idle for an hour keeps the same revision for that hour.
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

## Whatever the game contributes: round number, scores, teams, next map.
##
## Free-form on purpose. This is the section A2S has no room for, and the reason a
## game currently has to smuggle its state into the keywords string.
var game: Dictionary = {}

## Sides and their sizes, when a team roster is present.
##
## Separate from [member game] because a server browser can render a team list
## without knowing the game: two sides with counts and scores is the same shape in
## every team game there has ever been. A game with no teams leaves it empty.
var teams: Dictionary = {}

## What is playing, what is next, and what the rotation holds.
##
## The question a player deciding whether to join actually asks, and the one A2S
## cannot answer at all: a server on a map you dislike is worth joining if the next
## one is a map you like.
var rotation: Dictionary = {}

## Server health: tick, frame time, memory, uptime.
##
## [b]For an operator and a monitor, not for a player.[/b] Published because the
## alternative is every operator writing the same RCON scraper, and withheld from
## the revision hash because every field in it changes every frame.
var perf: Dictionary = {}

## Engine, addon and platform versions.
##
## Static for the life of the process, which makes it the cheapest section to
## build and the one most worth caching hard. A tracker that reports "17 servers
## still on the old build" needs exactly this.
var build: Dictionary = {}

## Declared statistics and their server-wide totals.
##
## Filled by the dot-stats bridge when one is attached. The schema half is what
## makes the numbers legible: a querier receiving [code]{"kills": 4210}[/code] with
## no units, no display name and no merge rule cannot render it.
var stats: Dictionary = {}

## Per-player statistics, for the players currently connected.
##
## [b]Off unless an operator turns it on, and never keyed by account id.[/b] See
## [DotQueryStats] for why both halves of that sentence are load-bearing.
var player_stats: Array = []

## Sections that were cut short by a size or policy limit.
##
## Reported rather than silently truncated, because a tracker showing 128 of 400
## players with no indication is worse than one showing none.
var truncated: PackedStringArray = PackedStringArray()


func _init() -> void:
	built_at = int(Time.get_unix_time_from_system())


# --- Access ----------------------------------------------------------------

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


# --- Serialisation ---------------------------------------------------------

## The DQP response body, carrying only the sections that were asked for.
##
## Unknown section names are reported in [code]unknown[/code] rather than ignored:
## a querier that misspells one otherwise sees an empty result and concludes the
## server has no players.
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
