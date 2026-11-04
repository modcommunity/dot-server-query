extends "res://examples/query_selftest_base.gd"

## The A2S and shared-UDP-port sections of the self-test.

const SHARED_PORT := 27093


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

	# Set AFTER the snapshot has been built and cached by the challenge round trip, so
	# this also checks that reporting a map drops the cache rather than leaving a listing
	# on the previous map for a rebuild interval.
	server.games.set_current_map("surf_selftest")
	var info_reply := query.handle_datagram(
		_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie), address, port
	)
	_check("A2S_INFO with a challenge is answered", info_reply.size() == 1)

	var info := _A2SReader.new(info_reply[0])
	_check("info is a single-packet response", info.single())
	_check("info has the 'I' header", info.u8() == DotA2SServer.RESPONSE_INFO)
	_check("info reports protocol 17", info.u8() == 17)
	_check("info carries the live hostname", info.cstring() == "Renamed For The Test")
	_check("info carries the map the game reported", info.cstring() == "surf_selftest")
	server.games.set_current_map("")
	# The app slug, not the configured default: a2s_game_folder ships as "dot" on every server,
	# useless as the grouping key A2S clients treat it as. An operator who pins their own still wins (_test_app_url).
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
	# The one extensible field A2S has, pointing a tracker at the protocol
	# that will actually tell it something.
	_check("keywords advertise the dot query port", keywords.contains("dqp:"))
	_check("info was read exactly to its end", info.at_end())
	_test_a2s_queries(query, address, port, cookie)


func _test_a2s_queries(query: DotQueryServer, address: String, port: int, cookie: int) -> void:
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
	_check("A2S's version is the running game's, not the framework constant",
		DotA2SServer.a2s_version({"version": "0.1.0", "game_version": "0.1.14"}) == "0.1.14")
	_check("with no game running, A2S's version is the server's",
		DotA2SServer.a2s_version({"version": "0.1.0", "game_version": ""}) == "0.1.0")
	_done()


## ENet, DQP and A2S on ONE UDP port over real sockets: the transport's demux owns the port
## and this addon is a handler on it.
func _test_shared_udp_port() -> void:
	print("")
	_section("[enet, dqp and a2s on one udp port]")

	var config := DotServerConfig.new()
	config.port = SHARED_PORT
	config.max_players = 4
	config.tickrate = 30
	config.rcon_password = ""
	config.hostname = "shared udp"
	config.query_enabled = true
	config.query_websocket = false
	config.a2s_enabled = true
	config.startup_config = ""
	config.autoexec_config = ""
	config.hibernate_when_empty = false
	DotPaths.remove_tree("user://queryexample-shared")
	config.admins_path = "user://queryexample-shared/admins.json"
	config.bans_path = "user://queryexample-shared/bans.json"
	config.audit_log_path = "user://queryexample-shared/audit.jsonl"

	var shared := DotServer.new()
	shared.name = "SharedServer"
	shared.config = config
	shared.config_file = ""
	shared.auto_boot = false
	add_child(shared)
	# Its own MultiplayerAPI: the suite's first server holds the tree's, and two
	# servers on one API would each hear the other's peers join.
	get_tree().set_multiplayer(SceneMultiplayer.new(), shared.get_path())

	var shared_host := DotQueryHost.new()
	shared_host.name = "SharedQueryHost"
	shared_host.server_ref = DotNodeRef.of_path(NodePath("../SharedServer"))
	add_child(shared_host)

	var booted: DotResult = await shared.boot()
	_check("a dual-stack server boots with queries on its port", booted.ok)
	if not booted.ok:
		return
	await get_tree().process_frame

	_check("ENet is advertised on the game port", shared.enet_port() == SHARED_PORT)
	_check("DQP is a handler on the shared socket",
		shared_host.query != null and shared_host.query.is_listening())
	_check("DQP's info carries the ENet port",
		int(shared_host.source.snapshot().info.get("enet_port", 0)) == SHARED_PORT)

	var udp := PacketPeerUDP.new()
	udp.bind(0, "127.0.0.1")
	udp.set_dest_address("127.0.0.1", SHARED_PORT)
	udp.put_packet(_a2s_request(DotA2SServer.REQUEST_INFO, true, 0))
	var replies: Array[PackedByteArray] = []
	var deadline := Time.get_ticks_msec() + 3000
	while replies.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		while udp.get_available_packet_count() > 0:
			replies.append(udp.get_packet())
	_check("A2S on the game port is answered over a real socket",
		not replies.is_empty() and replies[0].decode_u32(0) == DotA2SServer.HEADER_SINGLE)

	var cookie := -1
	if not replies.is_empty():
		var reader := _A2SReader.new(replies[0])
		reader.single()
		reader.u8()
		cookie = reader.u32()
	udp.put_packet(_a2s_request(DotA2SServer.REQUEST_INFO, true, cookie))
	replies.clear()
	deadline = Time.get_ticks_msec() + 3000
	while replies.is_empty() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		while udp.get_available_packet_count() > 0:
			replies.append(udp.get_packet())
	_check("and its keywords name the ENet port",
		not replies.is_empty() and _bytes_contain(replies[0], ("udp:%d" % SHARED_PORT).to_utf8_buffer()))
	udp.close()
	await _test_shared_enet_join(shared, shared_host)


func _test_shared_enet_join(shared: DotServer, shared_host: DotQueryHost) -> void:
	var enet_res := DotTransportENet.new().create_client("127.0.0.1", SHARED_PORT)
	var client: MultiplayerPeer = enet_res.value if enet_res.ok else null
	var joined := false
	var deadline := Time.get_ticks_msec() + 5000
	while client != null and Time.get_ticks_msec() < deadline:
		client.poll()
		if not shared.sessions().is_empty():
			joined = true
			break
		await get_tree().process_frame
	_check("an ENet client joins through the same port", joined)

	var session: DotClientSession = shared.sessions()[0] if joined else null
	_check("and the server sees its real address, not the relay's",
		session != null and session.address == "127.0.0.1")
	_check("and knows it came over ENet",
		session != null and shared.peer_transport(session.peer_id) == "enet")

	if client != null:
		client.close()
	shared.shutdown("shared udp section done")
	shared_host.queue_free()
	shared.queue_free()
	_done()


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

	# The order below is the protocol's field order, not the numeric order of the bits.
	# A writer using the numeric order makes every client misparse silently (a port read out of a string).
	r.u16()                                       # port
	_check("the server id round-trips", r.u64() == 0x0110000112345678)
	_check("the spectator port round-trips", r.u16() == 27020)
	_check("the spectator name round-trips", r.cstring() == "Relay")
	_check("keywords still carry the dqp port", r.cstring().contains("dqp:"))
	_check("the game id round-trips", r.u64() == 4242)
	_check("nothing trails the extra data", r.at_end())
	_test_a2s_extra_absent(query, a2s, address, port, cookie)


func _test_a2s_extra_absent(query: DotQueryServer, a2s: DotA2SServer, address: String, port: int, cookie: int) -> void:
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
