class_name DotQueryProtocol
extends RefCounted

## The dot query protocol (DQP) wire format: a fixed little-endian header, then JSON (optionally gzip).
## Header: magic "DQP1"(4) type(1) flags(1) txn(4) response id(4) fragment count(2) index(2) cookie(8).
## The magic differs from A2S's FF FF FF FF so one UDP socket can serve both.

const MAGIC := "DQP1"
const MAGIC_BYTES := 4
const HEADER_BYTES := 26

## Bumped only for an incompatible header change. The JSON body is versioned by
## its own [code]rev[/code] and by fields simply appearing.
const VERSION := 1

## Requests.
const TYPE_QUERY := 0x01
const TYPE_CHALLENGE_REQUEST := 0x02
const TYPE_PING := 0x03

## Responses. The high bit is set on every one of them, so a listener can tell a
## request from a reflected response without parsing further.
const TYPE_RESULT := 0x81
const TYPE_CHALLENGE := 0x82
const TYPE_ERROR := 0x83
const TYPE_PONG := 0x84

## The payload of [b]this[/b] packet is gzip-compressed.
const FLAG_GZIP := 1 << 0

## Set on every fragment of a fragmented response, including the first.
const FLAG_FRAGMENTED := 1 << 1

## On a request: the sender can decompress a gzip response.
## Not the same bit as [constant FLAG_GZIP], or a header would not describe itself without knowing its direction.
const FLAG_ACCEPT_GZIP := 1 << 2

## Kept under IPv6's minimum MTU (1280) with header room; an IP-fragmented datagram gets dropped by middleboxes.
const MAX_DATAGRAM := 1200
const MAX_PAYLOAD := MAX_DATAGRAM - HEADER_BYTES

## A response is never allowed to become more than this many datagrams (the amplification ceiling).
const MAX_FRAGMENTS := 16

## Requests are small by construction; anything larger is not one.
const MAX_REQUEST_BYTES := 1024

## Largest response body that can be framed, before compression is considered.
const MAX_RESPONSE_BYTES := MAX_FRAGMENTS * MAX_PAYLOAD

## Cap on a reassembled body, for the client half.
const MAX_BODY_BYTES := 1 << 20


## Whether a datagram is plausibly DQP. Cheap enough to run on every packet.
static func looks_like_dqp(data: PackedByteArray) -> bool:
	if data.size() < HEADER_BYTES:
		return false
	return data.slice(0, MAGIC_BYTES).get_string_from_ascii() == MAGIC


## Reads a datagram's header, and its body when it carries one.
## Returns [code]type, flags, txn, response_id, fragment_count, fragment_index, challenge, payload[/code]
## and, for a JSON payload that parsed, [code]body[/code].
static func parse(data: PackedByteArray) -> DotResult:
	if not looks_like_dqp(data):
		return DotResult.fail(
			DotError.CODE_PARSE, "Not a dot query packet."
		)

	var payload := data.slice(HEADER_BYTES)
	var flags := data.decode_u8(5)
	var type := data.decode_u8(4)

	if (flags & FLAG_GZIP) and not (type & 0x80):
		# Refused before decompressing: a compressed request is a broken client or a zip bomb.
		return DotResult.fail(
			DotError.CODE_INVALID, "Requests are not compressed."
		)

	# A fragment is a slice of a compressed whole; gunzipping or parsing it before reassemble() logs engine errors.
	var is_fragment := bool(flags & FLAG_FRAGMENTED)

	if (flags & FLAG_GZIP) and not is_fragment:
		var inflated := _gunzip(payload)
		if not inflated.ok:
			return inflated
		payload = inflated.value

	var out := {
		"type": type,
		"flags": flags,
		"txn": data.decode_u32(6),
		"response_id": data.decode_u32(10),
		"fragment_count": data.decode_u16(14),
		"fragment_index": data.decode_u16(16),
		"challenge": data.decode_u64(18),
		"payload": payload,
	}

	if payload.is_empty() or is_fragment:
		out["body"] = {}
		return DotResult.success(out)

	var text := payload.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)

	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		# Not fatal for the caller: the raw payload is still there. A body that is
		# not an object is a protocol violation, not a transport failure.
		out["body"] = {}
		out["body_error"] = "payload is not a JSON object"
		return DotResult.success(out)

	out["body"] = parsed as Dictionary
	return DotResult.success(out)


## Validates a parsed packet as a request a server should act on.
static func check_request(packet: Dictionary) -> DotResult:
	var type := int(packet.get("type", 0))

	if type & 0x80:
		# A response arriving on a listening socket is either a reflected packet
		# from someone else's attack or a confused client. Never answered: doing so
		# is how a server becomes one leg of a reflection loop.
		return DotResult.fail(
			DotError.CODE_INVALID, "That is a response, not a request."
		)

	if type != TYPE_QUERY and type != TYPE_CHALLENGE_REQUEST and type != TYPE_PING:
		return DotResult.fail(
			DotError.CODE_VERSION, "Unknown request type %d." % type
		)

	if int(packet.get("fragment_count", 1)) != 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "Requests are never fragmented."
		)

	return DotResult.success(type)


## Encodes a JSON body, compressing it when allowed and worthwhile.
## Returns [code][bytes, flags][/code]. Bodies that already fit in one datagram skip compression.
static func encode_body(body: Dictionary, allow_gzip: bool) -> Array:
	var raw := JSON.stringify(body).to_utf8_buffer()

	if not allow_gzip or raw.size() <= MAX_PAYLOAD:
		return [raw, 0]

	var packed := raw.compress(FileAccess.COMPRESSION_GZIP)

	# A body that compresses to more than it started as is rare but possible, and
	# sending the larger one while claiming it is compressed would be absurd.
	if packed.is_empty() or packed.size() >= raw.size():
		return [raw, 0]

	return [packed, FLAG_GZIP]


## Builds the datagrams for one packet, fragmenting if the payload needs it.
## Every fragment carries the whole header, so a receiver can reassemble without seeing the first.
static func build(
	type: int,
	txn: int,
	challenge: int,
	payload: PackedByteArray,
	flags: int = 0,
	response_id: int = 0
) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []

	var total := 1
	if payload.size() > MAX_PAYLOAD:
		total = int(ceil(float(payload.size()) / float(MAX_PAYLOAD)))
		flags |= FLAG_FRAGMENTED

	if total > MAX_FRAGMENTS:
		# Clamping truncates the payload into an unparseable body. DotQueryServer refuses oversized
		# responses before this, so reaching it warns rather than looking like packet loss.
		DotLog.warn(
			"query",
			"a response exceeded the fragment ceiling and was truncated",
			{"bytes": payload.size(), "fragments": total, "ceiling": MAX_FRAGMENTS}
		)
		total = MAX_FRAGMENTS

	for index in range(total):
		var start := index * MAX_PAYLOAD
		var chunk := payload.slice(start, mini(start + MAX_PAYLOAD, payload.size()))

		var packet := PackedByteArray()
		packet.resize(HEADER_BYTES)
		packet.encode_u8(0, MAGIC.unicode_at(0))
		packet.encode_u8(1, MAGIC.unicode_at(1))
		packet.encode_u8(2, MAGIC.unicode_at(2))
		packet.encode_u8(3, MAGIC.unicode_at(3))
		packet.encode_u8(4, type)
		packet.encode_u8(5, flags)
		packet.encode_u32(6, txn)
		packet.encode_u32(10, response_id)
		packet.encode_u16(14, total)
		packet.encode_u16(16, index)
		packet.encode_u64(18, challenge)
		packet.append_array(chunk)

		out.append(packet)

	return out


static func build_error(
	txn: int, code: String, message: String
) -> Array[PackedByteArray]:
	var body := JSON.stringify({"code": code, "error": message}).to_utf8_buffer()
	return build(TYPE_ERROR, txn, 0, body)


static func build_challenge(txn: int, challenge: int) -> Array[PackedByteArray]:
	return build(TYPE_CHALLENGE, txn, challenge, PackedByteArray())


## Builds a request. Used by clients and by the self-test.
static func build_request(
	type: int,
	txn: int,
	challenge: int,
	body: Dictionary = {},
	accept_gzip: bool = true
) -> PackedByteArray:
	var payload := PackedByteArray()
	if not body.is_empty():
		payload = JSON.stringify(body).to_utf8_buffer()

	var flags := FLAG_ACCEPT_GZIP if accept_gzip else 0
	# A request never fragments — build() would happily do it, but a server that
	# reassembled requests would be holding attacker-controlled state.
	return build(type, txn, challenge, payload, flags)[0]


## Reassembles a complete response from its datagrams, in any order, and returns the parsed body.
## Fragments of different responses are rejected rather than blended into a body that parses wrongly.
static func reassemble(fragments: Array) -> DotResult:
	if fragments.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "No fragments.")

	var first := parse(fragments[0] as PackedByteArray)
	if not first.ok:
		return first

	var head: Dictionary = first.value
	var total := int(head["fragment_count"])
	var response_id := int(head["response_id"])

	if total == 1:
		return DotResult.success(head.get("body", {}))

	var chunks: Dictionary = {}
	var flags := 0

	for datagram in fragments:
		# Fragments are parsed with the compression step skipped: the payload is
		# only whole once every fragment is in place, so gunzipping one on its own
		# would fail. parse() is used for the header only.
		var data: PackedByteArray = datagram
		if not looks_like_dqp(data):
			continue
		if int(data.decode_u32(10)) != response_id:
			continue
		if int(data.decode_u16(14)) != total:
			continue

		flags = data.decode_u8(5)
		chunks[int(data.decode_u16(16))] = data.slice(HEADER_BYTES)

	if chunks.size() != total:
		return DotResult.fail(
			DotError.CODE_TIMEOUT,
			"Incomplete response: %d of %d fragments." % [chunks.size(), total]
		)

	var payload := PackedByteArray()
	for index in range(total):
		payload.append_array(chunks[index] as PackedByteArray)

	if flags & FLAG_GZIP:
		var inflated := _gunzip(payload)
		if not inflated.ok:
			return inflated
		payload = inflated.value

	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return DotResult.fail(
			DotError.CODE_PARSE, "Reassembled payload is not a JSON object."
		)

	return DotResult.success(parsed as Dictionary)


static func _gunzip(payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.success(payload)

	# decompress_dynamic rather than decompress: the uncompressed size is not on
	# the wire, and a bound is required so a hostile payload cannot be a zip bomb.
	var inflated := payload.decompress_dynamic(
		MAX_BODY_BYTES, FileAccess.COMPRESSION_GZIP
	)

	if inflated.is_empty():
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Could not decompress the payload.",
			"claimed gzip, %d bytes" % payload.size()
		)

	return DotResult.success(inflated)


static func type_name(type: int) -> String:
	match type:
		TYPE_QUERY: return "query"
		TYPE_CHALLENGE_REQUEST: return "challenge_request"
		TYPE_PING: return "ping"
		TYPE_RESULT: return "result"
		TYPE_CHALLENGE: return "challenge"
		TYPE_ERROR: return "error"
		TYPE_PONG: return "pong"
	return "unknown(%d)" % type
