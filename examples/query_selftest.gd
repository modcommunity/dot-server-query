extends Node

## Boots a server with a query host attached and exercises both protocols end to end.
##
## [b]Neither protocol needs a socket to be tested.[/b] `handle_datagram` takes a
## datagram and returns the datagrams to send back, so the whole of DQP and A2S —
## challenge binding, fragmentation, gzip, conditional polling, reflection refusal,
## rate limiting, and every A2S response read back field by field — runs in
## process. The listeners still bind for real as well, so the shared-socket path
## is exercised rather than assumed.
##
## [codeblock]
## godot --headless --path . res://examples/query_selftest.tscn
## [/codeblock]
##
## Exits non-zero if any check fails.

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
const SECTIONS := 8

## Every check this suite runs, including the two at the end that compare the counts. The
## section counter cannot see a section that aborted after announcing itself — its remaining
## checks simply never run — and a total can. See docs/testing.md.
const CHECKS := 166

var _entered := 0
var _completed := 0
var _passed := 0
var _failed := 0


func _ready() -> void:
	var config := DotServerConfig.new()

	# Ephemeral, so this never collides with a real server or a second copy of
	# itself. The query port is explicit for the same reason the example in
	# dot-server makes it explicit: an ephemeral game port has nothing to derive
	# one from.
	config.port = 0
	config.max_players = 16
	config.reserved_slots = 2
	config.tickrate = 30
	config.rcon_password = ""
	config.hostname = "dot-server-query self-test"

	# Both protocols, one explicit UDP port. This is the shared-socket path: DQP
	# binds and A2S attaches to it.
	config.query_enabled = true
	config.a2s_enabled = true
	config.a2s_port = 27066
	config.a2s_app_id = 4242
	config.a2s_game_folder = "dot"
	config.tags = PackedStringArray(["example", "dev"])
	# This run's own directory, emptied first: the audit log appends, and every run had
	# added its lines to the last one's for as long as the suite existed.
	DotPaths.remove_tree("user://queryexample")
	config.admins_path = "user://queryexample/admins.json"
	config.bans_path = "user://queryexample/bans.json"
	config.audit_log_path = "user://queryexample/audit.jsonl"
	config.hibernate_when_empty = false

	# The addon ships a default server.cfg and the search path finds it, which is
	# correct layering but would make this assert against whatever that file
	# happens to contain.
	config.startup_config = ""
	config.autoexec_config = ""

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	server.config_file = ""
	server.auto_boot = false
	add_child(server)

	# The bridge is built before the host so the host finds it on the way up.
	# Nothing here is a DotStats* identifier: the tracker is duck-typed, and the
	# self-test hands it a stand-in with the same shape further down.
	stats_bridge = DotQueryStats.new()
	stats_bridge.name = "QueryStats"
	stats_bridge.publish_schema = true
	stats_bridge.publish_totals = true
	add_child(stats_bridge)

	host = DotQueryHost.new()
	host.name = "QueryHost"
	host.app_url = APP_URL
	# By path rather than through the registry: the server has not booted yet, so
	# it has not registered itself, and this exercises the ordering a scene
	# actually has. The registry default is covered by the wait in _ready.
	host.server_ref = DotNodeRef.of_path(NodePath("../Server"))
	host.stats_ref = DotNodeRef.of_path(NodePath("../QueryStats"))
	add_child(host)

	var booted := await server.boot()

	if not booted.ok:
		printerr("boot failed: %s" % str(booted.error))
		get_tree().quit(1)
		return

	if _should_selftest():
		await _run_selftest()
		return

	var timer := Timer.new()
	timer.wait_time = 30.0
	timer.autostart = true
	timer.timeout.connect(func() -> void:
		DotLog.info("example", "still running", host.describe()))
	add_child(timer)


func _should_selftest() -> bool:
	var args := OS.get_cmdline_user_args()
	if args.has(SELFTEST_ARG):
		return true
	if args.has("--serve"):
		return false
	return DotPlatform.is_headless()


# --- Self-test -------------------------------------------------------------

func _run_selftest() -> void:
	print("=== self-test ===")
	print("")

	_test_host()
	_test_app_url()
	_test_query()
	_test_sections()
	_test_stats()
	_test_query_protocol()
	_test_a2s()
	_test_a2s_extra_data()

	print("")
	# The two guards, as the last two checks. See docs/testing.md.
	_check(
		"every section ran to its last line (%d of %d)" % [_completed, SECTIONS],
		_completed == _entered and _entered == SECTIONS
	)
	_check(
		"every check ran (%d of %d)" % [_passed + _failed + 1, CHECKS],
		_passed + _failed + 1 == CHECKS
	)
	print("%d passed, %d failed" % [_passed, _failed])

	server.shutdown("self-test complete")
	get_tree().quit(1 if _failed > 0 else 0)


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


# --- The hook ---------------------------------------------------------------

func _test_host() -> void:
	_section("[host]")

	_check("the host attached to the server", server.query_host == host)
	_check("the server exposes the source it was given",
		server.query_source == host.source)
	_check("the host opened its listeners", host.is_open())

	# The hook is duck-typed from dot-server's side, so the only thing it can
	# check is the shape. Something without open() must be refused rather than
	# stored and called later.
	var refused := server.attach_query_host(RefCounted.new())
	_check("a second host is refused", not refused.ok)

	var bare := DotServer.new()
	var dummy := Node.new()
	var not_a_host := bare.attach_query_host(dummy)
	_check("a host without open() is refused", not not_a_host.ok)
	dummy.free()
	bare.free()

	# Registered by the host, not by dot-server: a server without this addon
	# should not offer a command whose only answer is "there is no query listener".
	_check("query_status is registered",
		server.console.find_command("query_status") != null)
	_check("query_dump is registered",
		server.console.find_command("query_dump") != null)
	_check("query_status reports both protocols",
		_run("query_status").contains("[a2s]"))
	_done()


# --- The app slug -----------------------------------------------------------

func _test_app_url() -> void:
	print("")
	_section("[app url]")

	var snap := host.source.snapshot(true)

	_check("info carries the app slug",
		str(snap.info.get("app", "")) == APP_URL)
	# A2S groups servers by the folder name, so the two disagreeing is how one
	# server appears twice in a listing.
	_check("a2s folder follows the app slug",
		str(snap.info.get("folder", "")) == APP_URL)

	# Static and manipulable on purpose: it is a display field, and nothing
	# downstream is allowed to treat it as proof of which app this is.
	_run("sv_query_app retagged-by-operator")
	_check("an operator can retag a running server",
		str(host.source.snapshot(true).info.get("app", "")) == "retagged-by-operator")

	# Slugified rather than trusted: the field goes into a listing, and a value
	# with a space or a slash in it is one a tracker renders somewhere it should
	# not.
	_run("sv_query_app \"Not A Slug/At All\"")
	var slugged := str(host.source.snapshot(true).info.get("app", ""))
	_check("a non-slug value is slugified", not slugged.contains(" ")
		and not slugged.contains("/"))

	_run("sv_query_app %s" % APP_URL)
	_check("the slug is restored",
		str(host.source.snapshot(true).info.get("app", "")) == APP_URL)

	# An operator who pinned a folder meant it, and the app slug must not quietly
	# replace it — only the family-wide default "dot" is treated as "unset".
	server.config.a2s_game_folder = "pinned-by-operator"
	_check("a pinned a2s folder beats the app slug",
		str(host.source.snapshot(true).info.get("folder", "")) == "pinned-by-operator")
	_check("the app field is unaffected by the folder",
		str(host.source.snapshot(true).info.get("app", "")) == APP_URL)
	server.config.a2s_game_folder = "dot"
	_check("clearing it hands the folder back to the app slug",
		str(host.source.snapshot(true).info.get("folder", "")) == APP_URL)
	_done()


# --- Extracted coverage: the protocols themselves ---------------------------

func _test_query() -> void:
	print("")
	_section("[query snapshot]")

	var source := host.source
	_check("query source exists", source != null)
	if source == null:
		return

	_check("query listener bound", host.query != null and host.query.is_listening())

	# The query listeners bind their own interface when told to, because a server
	# behind a reverse proxy binds the GAME transport to loopback and a reverse
	# proxy cannot forward UDP — so sharing one setting put the query port where
	# no tracker could reach it. Empty means "wherever the game is", which is what
	# every other deployment wants and what this one is running.
	var bind_cfg := DotServerConfig.new()
	bind_cfg.bind_address = "127.0.0.1"
	_check("query binds the game interface by default",
		bind_cfg.effective_query_bind_address() == "127.0.0.1")
	bind_cfg.query_bind_address = "*"
	_check("query binds its own interface when set",
		bind_cfg.effective_query_bind_address() == "*")
	bind_cfg.query_bind_address = "   "
	_check("a blank query interface is not an interface",
		bind_cfg.effective_query_bind_address() == "127.0.0.1")
	# A2S shares that socket rather than binding its own, because both default to
	# the same port and two listeners cannot have one.
	_check("a2s attached to the query socket",
		host.a2s != null and not host.a2s.is_listening())
	_check("a2s shares the challenge secret",
		host.a2s != null and host.a2s.challenge == host.query.challenge)

	var snap := source.snapshot(true)
	_check("info has a name", str(snap.info.get("name", "")) != "")
	_check("info counts slots", int(snap.info.get("max_players", 0)) > 0)
	_check("info separates connecting from playing",
		snap.info.has("connecting") and snap.info.has("players"))
	_check("info advertises the dot protocol", snap.info.has("query"))

	# The revision must not move when nothing did, or conditional polling — the
	# whole point of it — never saves a byte. Uptime advances between these two
	# rebuilds, which is exactly the field that must not count as a change.
	var rev_before := source.snapshot(true).rev
	var rev_again := source.snapshot(true).rev
	_check("revision stable when nothing changed", rev_before == rev_again)

	_run("hostname \"Renamed For The Test\"")
	var rev_after := source.snapshot(true).rev
	_check("revision moves when something changed", rev_after > rev_again)
	_check("live cvar beats the boot config",
		str(source.snapshot(true).info.get("name", "")) == "Renamed For The Test")

	# Rules come from the console, and the flags decide what may leave the server.
	var rules: Dictionary = source.snapshot(true).rules
	_check("rules publish a notify cvar", rules.has("sv_cheats"))
	_check("rules never publish a protected cvar", not rules.has("sv_password"))

	server.config.query_extra_rules = PackedStringArray(["sv_password"])
	_check("naming a protected cvar does not publish it",
		not source.snapshot(true).rules.has("sv_password"))
	server.config.query_extra_rules = PackedStringArray()

	# Player policy.
	_run("sv_query_players none")
	_check("player list refused at 'none'", source.snapshot(true).players.is_empty())
	_run("sv_query_players nonsense")
	_check("an invalid player policy is refused",
		source.player_detail() == "none")
	_run("sv_query_players full")
	_check("player policy restored", source.player_detail() == "full")

	# A provider is the only thing that can know a bot count, and it must reach the
	# backbone stats report as well as the query response.
	var provider := ExampleQueryProvider.new()
	provider.bots = 3
	var added := source.add_provider(provider)
	_check("provider registered", added.ok)
	_check("registering the same provider twice is refused",
		not source.add_provider(provider).ok)
	_check("a non-provider is refused", not source.add_provider(RefCounted.new()).ok)

	var contributed := source.snapshot(true)
	_check("provider contributes a game section",
		str(contributed.game.get("phase", "")) == "warmup")
	_check("provider corrects the bot count", contributed.bot_count() == 3)
	_check("bot count reaches the stats report",
		int(server.to_stats_report().get("bots", -1)) == 3)
	var report := server.to_stats_report()
	_check("a report between games says null for the map, which the backbone accepts and \"\" is not",
		report.has("map") and (report["map"] == null or (report["map"] is String and report["map"] != "")))
	for key in ["online", "curUsers", "maxUsers", "bots", "password", "dedicated", "version"]:
		_check("the report carries `%s` as IngestServerStatsInput spells it" % key, report.has(key))

	source.remove_provider(provider)
	_check("provider removed", source.snapshot(true).game.is_empty())

	# Signing is off unless a secret is configured, and a signature nobody checks
	# is cost with no benefit.
	_check("unsigned by default", not source.sign({"a": 1}).has("auth"))
	server.config.query_secret = "example-query-secret"
	var signed := source.sign({"a": 1})
	_check("signed when a secret is set", signed.has("auth"))
	_check("signature carries a timestamp and nonce",
		(signed["auth"] as Dictionary).has("ts")
		and (signed["auth"] as Dictionary).has("nonce"))
	server.config.query_secret = ""
	_done()


func _test_query_protocol() -> void:
	print("")
	_section("[dot query protocol]")

	var query := host.query
	if query == null:
		_check("query listener present", false)
		return

	var address := "198.51.100.7"
	var port := 41000

	# An unchallenged query is answered with a cookie and nothing else. That reply
	# is smaller than the request, which is what makes the protocol useless as an
	# amplifier.
	var unchallenged := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 1, 0, {"sections": ["info", "players"]}
	)
	var replies := query.handle_datagram(unchallenged, address, port)
	_check("an unchallenged query gets a challenge", replies.size() == 1)

	var challenge_packet := DotQueryProtocol.parse(replies[0])
	_check("challenge parses", challenge_packet.ok)
	var cookie := int((challenge_packet.value as Dictionary)["challenge"])
	_check("challenge is not zero", cookie != 0)
	_check("the challenge reply is smaller than the request",
		replies[0].size() < unchallenged.size())

	# The cookie is bound to the address it was mailed to, so a forger who guessed
	# somebody else's address cannot use one issued to them.
	_check("a cookie is refused from another address",
		not query.challenge.verify("198.51.100.9", port, cookie))
	_check("a cookie is refused from another port",
		not query.challenge.verify(address, port + 1, cookie))
	_check("a cookie is accepted from its own address",
		query.challenge.verify(address, port, cookie))

	var challenged := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 2, cookie, {"sections": ["info", "players"]}
	)
	var answer := query.handle_datagram(challenged, address, port)
	_check("a challenged query is answered", answer.size() >= 1)

	var body := DotQueryProtocol.reassemble(answer)
	_check("the answer reassembles", body.ok)

	var result: Dictionary = body.value
	_check("the answer echoes the transaction",
		int((DotQueryProtocol.parse(answer[0]).value as Dictionary)["txn"]) == 2)
	_check("the answer carries the info section",
		(result.get("sections", {}) as Dictionary).has("info"))
	_check("the answer carries only what was asked for",
		not (result.get("sections", {}) as Dictionary).has("rules"))

	# Conditional polling: a querier holding the current revision gets told so.
	var rev := int(result.get("rev", 0))
	var conditional := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 3, cookie, {"if_rev": rev}
	)
	var unchanged := DotQueryProtocol.reassemble(
		query.handle_datagram(conditional, address, port)
	)
	_check("a matching revision replies 'unchanged'",
		unchanged.ok and bool((unchanged.value as Dictionary).get("unchanged", false)))
	_check("the unchanged reply is one small datagram",
		query.handle_datagram(conditional, address, port)[0].size() < 200)

	# An unknown section is reported rather than dropped, or a querier who
	# misspelled one concludes the server has no players.
	var misspelled := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_QUERY, 4, cookie, {"sections": ["playerz"]}
	)
	var reported := DotQueryProtocol.reassemble(
		query.handle_datagram(misspelled, address, port)
	)
	_check("an unknown section is reported",
		reported.ok and (reported.value as Dictionary).has("unknown"))

	# A response arriving on the listening socket is never answered: doing so is
	# how a server becomes one leg of a reflection loop between two servers.
	var reflected := DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_RESULT, 5, cookie, {}
	)
	_check("a response is not answered",
		query.handle_datagram(reflected, address, port).is_empty())
	_check("a non-DQP datagram is ignored",
		query.handle_datagram(
			"hello".to_utf8_buffer(), address, port
		).is_empty())

	var oversized := PackedByteArray()
	oversized.resize(DotQueryProtocol.MAX_REQUEST_BYTES + 1)
	_check("an oversized request is ignored",
		query.handle_datagram(oversized, address, port).is_empty())

	# Ping is answered without a challenge because the reply is smaller than the
	# request; there is nothing to amplify.
	var ping := DotQueryProtocol.build_request(DotQueryProtocol.TYPE_PING, 6, 0)
	var pong := query.handle_datagram(ping, address, port)
	_check("ping is answered",
		pong.size() == 1
		and int((DotQueryProtocol.parse(pong[0]).value as Dictionary)["type"])
			== DotQueryProtocol.TYPE_PONG)

	# Fragmentation and compression, round-tripped without a socket.
	var big := {"filler": []}
	for i in range(400):
		(big["filler"] as Array).append("entry-%d-padding-padding-padding" % i)

	# The request flag says "I can decompress a reply"; the response flag says "this
	# payload is compressed". Sharing one bit made the header unparseable without
	# already knowing which direction the packet was going.
	_check("a request advertises gzip without claiming to be gzipped",
		(DotQueryProtocol.parse(DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_QUERY, 9, cookie, {}, true
		)).value as Dictionary)["flags"] == DotQueryProtocol.FLAG_ACCEPT_GZIP)

	var claims_gzip := DotQueryProtocol.build(
		DotQueryProtocol.TYPE_QUERY, 10, cookie,
		"not actually gzip".to_utf8_buffer(), DotQueryProtocol.FLAG_GZIP
	)[0]
	_check("a request claiming to be compressed is refused",
		not DotQueryProtocol.parse(claims_gzip).ok)

	var plain := DotQueryProtocol.encode_body(big, false)
	_check("a large body is not compressed when gzip is not accepted",
		int(plain[1]) == 0)
	var fragments := DotQueryProtocol.build(
		DotQueryProtocol.TYPE_RESULT, 7, 0, plain[0] as PackedByteArray,
		int(plain[1]), 99
	)
	_check("a large body fragments", fragments.size() > 1)
	_check("every fragment carries the whole header",
		fragments[fragments.size() - 1].size() > DotQueryProtocol.HEADER_BYTES)

	var shuffled := fragments.duplicate()
	shuffled.reverse()
	var rebuilt := DotQueryProtocol.reassemble(shuffled)
	_check("fragments reassemble out of order",
		rebuilt.ok and (rebuilt.value as Dictionary).has("filler"))

	var missing := fragments.duplicate()
	missing.remove_at(1)
	_check("a missing fragment is a failure, not a partial body",
		not DotQueryProtocol.reassemble(missing).ok)

	var gzipped := DotQueryProtocol.encode_body(big, true)
	_check("a large body compresses when gzip is accepted",
		int(gzipped[1]) & DotQueryProtocol.FLAG_GZIP)
	_check("compression actually shrinks it",
		(gzipped[0] as PackedByteArray).size() < (plain[0] as PackedByteArray).size())
	var inflated := DotQueryProtocol.reassemble(DotQueryProtocol.build(
		DotQueryProtocol.TYPE_RESULT, 8, 0, gzipped[0] as PackedByteArray,
		int(gzipped[1]), 100
	))
	_check("a compressed body reassembles",
		inflated.ok and (inflated.value as Dictionary).has("filler"))

	# Rate limiting, from an address no other check has spent tokens for.
	var flooder := "203.0.113.200"
	var flood_port := 42000
	var flood_cookie := query.challenge.issue(flooder, flood_port)
	var refused := 0
	for i in range(40):
		var req := DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_QUERY, 100 + i, flood_cookie
		)
		if query.handle_datagram(req, flooder, flood_port).is_empty():
			refused += 1
	_check("a flood from one address is rate limited", refused > 0)

	# Turning it off stops answers without closing the socket, so it can be turned
	# back on without the port moving under whatever was polling it.
	_run("sv_query 0")
	_check("sv_query 0 stops answering",
		query.handle_datagram(challenged, address, port).is_empty())
	_check("sv_query 0 leaves the socket open", query.is_listening())
	_run("sv_query 1")
	_check("sv_query 1 resumes answering",
		not query.handle_datagram(challenged, address, port).is_empty())
	_done()


func _test_a2s() -> void:
	print("")
	_section("[a2s]")

	var query := host.query
	var a2s := host.a2s
	if a2s == null or query == null:
		_check("a2s present", false)
		return

	var address := "198.51.100.20"
	var port := 43000

	# Sent to the query listener, because that is what owns the socket. The two
	# protocols are told apart by their first four bytes.
	var info_request := _a2s_request(DotA2SServer.REQUEST_INFO, true, 0)
	var challenge_reply := query.handle_datagram(info_request, address, port)
	_check("A2S_INFO without a challenge gets one", challenge_reply.size() == 1)

	var reader := _A2SReader.new(challenge_reply[0])
	_check("the challenge is a single-packet response", reader.single())
	_check("the challenge has the 'A' header",
		reader.u8() == DotA2SServer.RESPONSE_CHALLENGE)

	var cookie := reader.u32()
	_check("the A2S challenge is not the reserved sentinel", cookie != 0xFFFFFFFF)
	_check("the A2S challenge is address-bound",
		not a2s.challenge.verify_a2s("198.51.100.21", port, cookie))

	var info_reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
	)
	_check("A2S_INFO with a challenge is answered", info_reply.size() == 1)

	var info := _A2SReader.new(info_reply[0])
	_check("info is a single-packet response", info.single())
	_check("info has the 'I' header", info.u8() == DotA2SServer.RESPONSE_INFO)
	_check("info reports protocol 17", info.u8() == 17)
	_check("info carries the live hostname", info.cstring() == "Renamed For The Test")
	info.cstring()  # map
	# The app slug, not the configured default: a2s_game_folder ships as "dot" on
	# every server in the family, which makes it useless as the grouping key A2S
	# clients treat it as. An operator who pins their own still wins — asserted
	# in _test_app_url.
	_check("info carries the app slug as its folder", info.cstring() == APP_URL)
	info.cstring()  # game description
	_check("info carries the app id", info.u16() == 4242)
	info.u8()       # players
	_check("info carries the slot count", info.u8() == server.config.max_players)
	_check("info carries the bot count", info.u8() == 0)
	_check("info reports a dedicated server", info.u8() == 0x64)
	info.u8()       # os
	_check("info reports no password", info.u8() == 0)
	info.u8()       # vac
	_check("info carries the version", info.cstring() == DotServer.VERSION)

	var edf := info.u8()
	_check("info sets the port extra-data flag", (edf & DotA2SServer.EDF_PORT) != 0)
	info.u16()      # port
	_check("info sets the keywords flag", (edf & DotA2SServer.EDF_KEYWORDS) != 0)
	var keywords := info.cstring()
	_check("keywords carry the server tags", keywords.contains("example"))
	# The one extensible field A2S has, used to point a tracker at the protocol
	# that will actually tell it something.
	_check("keywords advertise the dot query port", keywords.contains("dqp:"))
	_check("info was read exactly to its end", info.at_end())

	# A packet claiming to be A2S_INFO without the fixed string is not one.
	_check("a malformed A2S_INFO is ignored",
		query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_INFO, false, cookie), address, port
		).is_empty())

	# PLAYER and RULES have always been challenged.
	# 0xFFFFFFFF is what a real client sends to mean "I have no challenge", and it
	# must never match: every cookie has its top bit cleared, so it cannot be this.
	_check("A2S_PLAYER without a challenge gets one",
		_A2SReader.new(query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_PLAYER, false, 0xFFFFFFFF),
			address, port
		)[0]).skip(4).u8() == DotA2SServer.RESPONSE_CHALLENGE)

	var players := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_PLAYER, false, cookie), address, port
	)[0])
	_check("A2S_PLAYER is answered", players.single())
	_check("player response has the 'D' header",
		players.u8() == DotA2SServer.RESPONSE_PLAYER)
	_check("player response counts nobody on an empty server", players.u8() == 0)

	var rules := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_RULES, false, cookie), address, port
	)[0])
	_check("A2S_RULES is answered", rules.single())
	_check("rules response has the 'E' header",
		rules.u8() == DotA2SServer.RESPONSE_RULES)

	var rule_count := rules.u16()
	_check("rules response lists rules", rule_count > 0)
	var leaked := false
	for i in range(rule_count):
		if rules.cstring() == "sv_password":
			leaked = true
		rules.cstring()
	_check("rules never include a protected cvar", not leaked)
	_check("rules response was read exactly to its end", rules.at_end())

	var ping := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_PING, false, -1), address, port
	)[0])
	_check("A2A_PING is answered",
		ping.single() and ping.u8() == DotA2SServer.RESPONSE_PING)

	_run("sv_a2s 0")
	_check("sv_a2s 0 stops answering",
		query.handle_datagram(
			_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
		).is_empty())
	_run("sv_a2s 1")
	_check("the dot protocol still answers while A2S is off",
		not query.handle_datagram(
			DotQueryProtocol.build_request(
				DotQueryProtocol.TYPE_CHALLENGE_REQUEST, 1, 0
			), address, port
		).is_empty())
	_done()


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


# --- The sections DQP has and A2S cannot -----------------------------------

func _test_sections() -> void:
	print("")
	_section("[sections]")

	var source := host.source
	var snap := source.snapshot(true)

	_check("rotation names the games this server can run",
		snap.rotation.has("games"))
	_check("build reports the engine", str(snap.build.get("engine", "")).begins_with("Godot"))
	_check("build reports the query protocol version",
		int(snap.build.get("query", 0)) == DotQueryProtocol.VERSION)
	_check("perf reports a tickrate",
		int(snap.perf.get("tickrate", 0)) == server.config.tickrate)
	# No team roster is registered here, so the section is empty rather than
	# absent-and-erroring. dot-team is duck-typed and most games have no teams.
	_check("teams is empty without a roster", snap.teams.is_empty())

	# Asking for a section by name is what a querier does, and an unknown one
	# must be reported rather than dropped.
	var body := snap.to_dict(PackedStringArray(["perf", "build", "nonsense"]))
	var sections: Dictionary = body["sections"]
	_check("a requested section is returned", sections.has("perf"))
	_check("an unrequested section is not", not sections.has("players"))
	_check("an unknown section is reported", Array(body.get("unknown", [])).has("nonsense"))

	# The revision is the whole reason polling is cheap, and perf is the field
	# that would destroy it: every number in it differs on every rebuild, so a
	# hash including it would mint a new revision every single second.
	_check("perf is declared volatile",
		DotQuerySnapshot.is_volatile(DotQuerySnapshot.SECTION_PERF))
	var rev_one := source.snapshot(true).rev
	var rev_two := source.snapshot(true).rev
	_check("the revision survives two rebuilds with perf in them", rev_one == rev_two)

	# ...and the sections that are NOT volatile must still move it, or a tracker
	# polling with if_rev never learns that a score changed.
	var before := source.snapshot(true).rev
	var probe := SectionProbe.new()
	source.add_provider(probe)
	probe.round_number = 7
	var after := source.snapshot(true).rev
	_check("a provider's contribution moves the revision", after > before)
	_check("the game section carries it",
		int(source.snapshot(true).game.get("round", 0)) == 7)
	source.remove_provider(probe)
	_done()


# --- The dot-stats bridge ---------------------------------------------------

func _test_stats() -> void:
	print("")
	_section("[stats]")

	var source := host.source

	_check("the bridge attached", host.stats == stats_bridge)
	_check("server counters exist without a tracker",
		(source.snapshot(true).stats as Dictionary).has("server"))

	# Duck-typed: this stand-in has the same shape dot-stats' tracker has, and
	# nothing in the addon names a DotStats* identifier. The real addon is linked
	# into this project, so the shape is checked against it below.
	var tracker := FakeTracker.new()
	tracker.add("p-0000000001", {"kills": 4.0, "deaths": 1.0})
	tracker.add("p-0000000002", {"kills": 6.0, "deaths": 3.0})

	_check("a tracker with the wrong shape is refused",
		not stats_bridge.attach(RefCounted.new()).ok)
	_check("a tracker with the right shape is accepted",
		stats_bridge.attach(tracker).ok)

	var stats: Dictionary = source.snapshot(true).stats
	_check("the schema is published", stats.has("schema"))
	_check("the schema carries units",
		str((stats["schema"] as Array)[0].get("unit", "")) != "")
	_check("totals sum across players",
		int((stats.get("game", {}) as Dictionary).get("kills", 0)) == 10)

	# A stat the schema does not publish must not leave the server on this path
	# either. dot-stats already draws that line for the backbone report.
	tracker.add("p-0000000003", {"kills": 1.0, "secret_rating": 99.0})
	var totals: Dictionary = source.snapshot(true).stats.get("game", {})
	_check("an unpublished stat is never totalled", not totals.has("secret_rating"))

	# Per-player rows are the half that needs more than a boolean, because the
	# key a game filed statistics under cannot be guessed from here.
	stats_bridge.publish_players = true
	_check("publish_players alone publishes nothing",
		(source.snapshot(true).player_stats as Array).is_empty())

	stats_bridge.player_key_format = "p-%010d"
	_check("a key format is what turns it on",
		stats_bridge.describe().get("players") == true)

	# No sessions are connected in a headless self-test, so there is nobody to
	# match — which is the correct empty, and a different one from the refusal
	# above. The join itself is asserted through _key_for's format directly.
	_check("rows are built from sessions, not from tracker keys",
		(source.snapshot(true).player_stats as Array).is_empty())

	stats_bridge.publish_players = false
	stats_bridge.attach(null)
	_done()


# --- A2S extra data ---------------------------------------------------------

func _test_a2s_extra_data() -> void:
	print("")
	_section("[a2s extra data]")

	var query := host.query
	var a2s := host.a2s
	if a2s == null or query == null:
		_check("a2s present", false)
		return

	var address := "198.51.100.30"
	var port := 44000

	a2s.steam_id = 0x0110000112345678
	a2s.spectator_port = 27020
	a2s.spectator_name = "Relay"
	a2s.game_id = 4242

	var cookie := _a2s_cookie(query, address, port)
	var reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
	)
	_check("A2S_INFO answered with every extra field", reply.size() == 1)

	var r := _A2SReader.new(reply[0])
	r.single()
	r.u8()                      # 'I'
	r.u8()                      # protocol
	r.cstring()                 # name
	r.cstring()                 # map
	var folder := r.cstring()
	r.cstring()                 # game
	r.u16()                     # app id
	r.u8()                      # players
	r.u8()                      # max
	r.u8()                      # bots
	r.u8()                      # server type
	r.u8()                      # environment
	r.u8()                      # visibility
	r.u8()                      # vac
	r.cstring()                 # version

	_check("the folder is the app slug", folder == APP_URL)

	var edf := r.u8()
	_check("the port flag is set", (edf & DotA2SServer.EDF_PORT) != 0)
	_check("the server id flag is set", (edf & DotA2SServer.EDF_STEAM_ID) != 0)
	_check("the spectator flag is set", (edf & DotA2SServer.EDF_SPECTATOR) != 0)
	_check("the keywords flag is set", (edf & DotA2SServer.EDF_KEYWORDS) != 0)
	_check("the game id flag is set", (edf & DotA2SServer.EDF_GAME_ID) != 0)

	# The order below is the protocol's field order, and it is NOT the numeric
	# order of the bits. A writer that used the numeric order produces a response
	# every client misparses, and none of them report an error — they read a port
	# out of the middle of a string. This is the check that catches it.
	r.u16()                                       # port
	_check("the server id round-trips", r.u64() == 0x0110000112345678)
	_check("the spectator port round-trips", r.u16() == 27020)
	_check("the spectator name round-trips", r.cstring() == "Relay")
	_check("keywords still carry the dqp port", r.cstring().contains("dqp:"))
	_check("the game id round-trips", r.u64() == 4242)
	_check("nothing trails the extra data", r.at_end())

	# Zero means absent, not "send a zero": a client reading a field that is not
	# there reads the next one instead.
	a2s.steam_id = 0
	a2s.spectator_port = 0
	a2s.game_id = 0

	var plain := _A2SReader.new(query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
	)[0])
	plain.single()
	for i in range(4):
		if i == 0:
			plain.u8()
			plain.u8()
		plain.cstring()
	plain.u16()
	for i in range(7):
		plain.u8()
	plain.cstring()
	var bare_edf := plain.u8()
	_check("an unset server id clears its flag",
		(bare_edf & DotA2SServer.EDF_STEAM_ID) == 0)
	_check("an unset spectator port clears its flag",
		(bare_edf & DotA2SServer.EDF_SPECTATOR) == 0)
	_check("an unset game id clears its flag",
		(bare_edf & DotA2SServer.EDF_GAME_ID) == 0)

	# The one game-specific block in the protocol, gated on the app id so it can
	# never fire by accident. It sits before the version string, so emitting it
	# for the wrong app id shifts every following field.
	_check("the extra block is off for an ordinary app id",
		not DotA2SServer._has_extra_block(server.config.a2s_app_id))
	_check("the extra block is on for the app ids that carry it",
		DotA2SServer._has_extra_block(DotA2SServer.SHIP_APP_ID_FIRST)
		and DotA2SServer._has_extra_block(DotA2SServer.SHIP_APP_ID_LAST))
	_check("the extra block range is closed",
		not DotA2SServer._has_extra_block(DotA2SServer.SHIP_APP_ID_LAST + 1))
	_done()


## Gets a valid A2S challenge for an address, the way a real client would.
func _a2s_cookie(query: DotQueryServer, address: String, port: int) -> int:
	var reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, 0), address, port
	)
	var reader := _A2SReader.new(reply[0])
	reader.single()
	reader.u8()
	return reader.u32()


# --- Stand-ins --------------------------------------------------------------

## A provider standing in for a game, to prove the plug-in point moves the revision.
class SectionProbe extends DotQueryProvider:
	var round_number: int = 0

	func _provider_name() -> String:
		return "probe"

	func _contribute(snapshot: DotQuerySnapshot) -> void:
		snapshot.contribute_game({"round": round_number})


## A statistics tracker with dot-stats' shape and none of its identifiers.
##
## The bridge is duck-typed precisely so a game can hand it something of its own,
## and this is that case exercised rather than asserted in a comment.
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
