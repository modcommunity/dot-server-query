extends "res://examples/query_selftest_mid.gd"

## Boots a server with a query host attached and exercises both protocols end to end, in process:
## [code]handle_datagram[/code] takes a datagram and returns the replies; the listeners still bind for real.
## Run: [code]godot --headless --path . res://examples/query_selftest.tscn[/code]. Exits non-zero on failure.


func _ready() -> void:
	var config := DotServerConfig.new()

	# Ephemeral, so this never collides with a real server or a second copy of itself.
	# The query port is explicit because an ephemeral game port has nothing to derive one from.
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
	await _test_shared_udp_port()

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


func _test_query() -> void:
	print("")
	_section("[query snapshot]")

	var source := host.source
	_check("query source exists", source != null)
	if source == null:
		return

	_check("query listener bound", host.query != null and host.query.is_listening())

	# The query listeners bind their own interface when told to: behind a reverse proxy the GAME
	# transport sits on loopback and UDP cannot be proxied. Empty means "wherever the game is".
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
	_test_query_provider(source)


func _test_query_provider(source: DotQuerySource) -> void:
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

	# The map is the GAME's to say. It was the content id unconditionally, which every
	# listing printed as `owner/repo` in its map column.
	server.games.set_current_map("dm_selftest")
	_check("a map the game reports is the query's map",
		str(source.snapshot(true).info.get("map", "")) == "dm_selftest")
	_check("and the backbone report's", server.to_stats_report().get("map") == "dm_selftest")
	server.games.set_current_map("")
	_check("a game that reports none falls back to the game, as before",
		str(source.snapshot(true).info.get("map", "")) == server.games.reported_map()
		and server.games.current_map() == "")

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
	_test_query_protocol_junk(query, address, port, cookie)
	_test_query_protocol_fragments(cookie)
	_test_query_protocol_limits(query, address, port, challenged)


func _test_query_protocol_junk(query: DotQueryServer, address: String, port: int, cookie: int) -> void:
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


func _test_query_protocol_fragments(cookie: int) -> void:
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


func _test_query_protocol_limits(query: DotQueryServer, address: String, port: int, challenged: PackedByteArray) -> void:
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

	# The limiter is keyed by an address nobody has proved yet, so forged addresses must not grow it:
	# one never-evicted bucket per spoofed datagram is the memory-exhaustion target. Small cap keeps the suite quick.
	var known := "192.0.2.50"
	query._limiter.max_tracked = 64
	query.handle_datagram(DotQueryProtocol.build_request(
		DotQueryProtocol.TYPE_CHALLENGE_REQUEST, 1, 0), known, 40000)
	for i in range(500):
		query.handle_datagram(DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_CHALLENGE_REQUEST, 1, 0
		), "10.9.%d.%d" % [i / 256, i % 256], 40000)
	_check("forged addresses cannot grow the DQP limiter (%d held)"
		% query._limiter.tracked_count(), query._limiter.tracked_count() <= 65)
	_check("an address it already knew is still answered",
		not query.handle_datagram(DotQueryProtocol.build_request(
			DotQueryProtocol.TYPE_CHALLENGE_REQUEST, 2, 0), known, 40000).is_empty())
	query._limiter.max_tracked = DotQueryLimiter.DEFAULT_MAX_TRACKED

	if host.a2s != null:
		host.a2s._limiter.max_tracked = 64
		for i in range(500):
			host.a2s.handle_datagram(
				_a2s_request(DotA2SServer.REQUEST_PLAYER, false, 0xFFFFFFFF),
				"10.10.%d.%d" % [i / 256, i % 256], 40000
			)
		_check("nor the A2S one (%d held)" % host.a2s._limiter.tracked_count(),
			host.a2s._limiter.tracked_count() <= 65)
		host.a2s._limiter.max_tracked = DotQueryLimiter.DEFAULT_MAX_TRACKED
	else:
		_check("nor the A2S one (no A2S server)", false)

	# A refilled bucket is the same as no bucket, so the table sheds those rather
	# than waiting on an idle timeout — the base sweep compared the stored count and
	# never shed a key that had sent one packet.
	var shed := DotQueryLimiter.new(1000.0, 1.0)
	shed.max_tracked = 8
	for i in range(8):
		shed.allow("198.18.0.%d" % i)
	OS.delay_msec(20)
	var fresh_allowed := shed.allow("198.18.1.1")
	_check("a full table sheds refilled buckets before sharing one",
		fresh_allowed and shed.overflowed() == 0 and shed.tracked_count() <= 8)

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
