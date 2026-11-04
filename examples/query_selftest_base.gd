extends Node

## Harness for the self-test: counters, check helpers, the A2S wire helpers and the stand-in providers.

const SELFTEST_ARG := "--selftest"

## The app's URL segment on the website. Static, display-only, and the field a
## listing prints to say which game this is.
const APP_URL := "dot-example-arena"

var server: DotServer
var host: DotQueryHost
var stats_bridge: DotQueryStats

## Sections entered against sections that ran to their last line, and against this. A
## runtime error inside a section aborts that function and nothing says so; a section that
## bailed out early after a failed guard is counted as not finished on purpose.
const SECTIONS := 9

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 185

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0


func _section(title: String) -> void:
	_entered += 1
	print(title)


## A section reached its last line. See [constant SECTIONS].
func _done() -> void:
	_completed += 1


func _check(what: String, passed: bool) -> void:
	if passed:
		_passed += 1
		print("  %-52s ok" % what)
	else:
		_failed += 1
		print("  %-52s FAILED" % what)


## Runs a command as the local console and returns its output.
func _run(line: String) -> String:
	var lines := PackedStringArray()
	var ctx := DotCmdContext.console("", PackedStringArray())
	ctx.reply_sink = func(text: String) -> void: lines.append(text)
	server.console.execute(line, ctx)
	return "\n".join(lines)


func _bytes_contain(haystack: PackedByteArray, needle: PackedByteArray) -> bool:
	for i in haystack.size() - needle.size() + 1:
		if haystack.slice(i, i + needle.size()) == needle:
			return true
	return false


## Builds an A2S request. [param challenge] of -1 appends nothing.
func _a2s_request(request: int, with_payload: bool, challenge: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(5)
	out.encode_u32(0, DotA2SServer.HEADER_SINGLE)
	out.encode_u8(4, request)

	if with_payload:
		out.append_array(DotA2SServer.INFO_PAYLOAD.to_utf8_buffer())
		out.append(0)

	if challenge >= 0:
		var tail := PackedByteArray()
		tail.resize(4)
		tail.encode_u32(0, challenge)
		out.append_array(tail)

	return out


## Reads an A2S response the way a real client would, so the encoding is checked
## field by field rather than by its length.
class _A2SReader extends RefCounted:
	var data: PackedByteArray
	var offset: int = 0

	func _init(p_data: PackedByteArray) -> void:
		data = p_data

	## Consumes the single-packet header.
	func single() -> bool:
		if data.size() < 4:
			return false
		offset = 4
		return data.decode_u32(0) == DotA2SServer.HEADER_SINGLE

	func skip(n: int) -> _A2SReader:
		offset += n
		return self

	func u8() -> int:
		var v := data.decode_u8(offset)
		offset += 1
		return v

	func u16() -> int:
		var v := data.decode_u16(offset)
		offset += 2
		return v

	func u32() -> int:
		var v := data.decode_u32(offset)
		offset += 4
		return v

	func u64() -> int:
		var v := data.decode_u64(offset)
		offset += 8
		return v

	func cstring() -> String:
		var start := offset
		while offset < data.size() and data.decode_u8(offset) != 0:
			offset += 1
		var text := data.slice(start, offset).get_string_from_utf8()
		offset += 1
		return text

	func at_end() -> bool:
		return offset == data.size()


## Gets a valid A2S challenge for an address, the way a real client would.
func _a2s_cookie(query: DotQueryServer, address: String, port: int) -> int:
	var reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, 0), address, port
	)
	var reader := _A2SReader.new(reply[0])
	reader.single()
	reader.u8()
	return reader.u32()


## A provider standing in for a game, to prove the plug-in point moves the revision.
class SectionProbe extends DotQueryProvider:
	var round_number: int = 0

	func _provider_name() -> String:
		return "probe"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		snapshot.contribute_game({"round": round_number})


## A statistics tracker with dot-stats' shape and none of its identifiers.
## The bridge is duck-typed so a game can hand it something of its own; this exercises that case.
class FakeTracker extends RefCounted:
	var schema := FakeSchema.new()
	var _rows: Dictionary = {}

	func add(key: String, values: Dictionary) -> void:
		_rows[key] = FakeValues.new(values)

	func players() -> Array:
		return _rows.keys()

	func session_values(key: StringName) -> Object:
		return _rows.get(String(key))


class FakeSchema extends RefCounted:
	func published() -> Array:
		return [
			FakeDef.new(&"kills", "Kills", "kills"),
			FakeDef.new(&"deaths", "Deaths", "deaths"),
		]


class FakeDef extends RefCounted:
	var id: StringName
	var display_name: String
	var unit: String
	var decimals: int = 0

	func _init(p_id: StringName, p_name: String, p_unit: String) -> void:
		id = p_id
		display_name = p_name
		unit = p_unit

	func kind_name() -> String:
		return "counter"


class FakeValues extends RefCounted:
	var _values: Dictionary

	func _init(p_values: Dictionary) -> void:
		_values = p_values

	func to_dictionary() -> Dictionary:
		return _values


## A provider standing in for a game, so the plug-in point is exercised.
class ExampleQueryProvider extends DotQueryProvider:
	var bots: int = 0

	func _provider_name() -> String:
		return "example"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		snapshot.info["bots"] = bots
		snapshot.contribute_game({"phase": "warmup", "round": 1})
