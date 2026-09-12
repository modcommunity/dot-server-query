@tool
class_name DotQueryHost
extends Node

## Plugs the query responders into a [DotServer], and owns their lifetime.
##
## [b]This node is the whole integration.[/b] dot-server names nothing in this
## addon: it holds a hook, and this fills it. Add a [DotQueryHost] to a server's
## scene and the server answers queries; leave it out and dot-server still parses,
## still boots and still installs with dot-core alone, which is the property that
## made the query code worth moving out in the first place. A script mentioning a
## [code]class_name[/code] the project does not have fails to parse and takes every
## script referencing it down with it, so an optional addon that dot-server named
## directly would not be optional at all.
##
## What it brings up, in the order it has to:
##
## 1. [DotQuerySource], because both protocols read from it and neither can start
##    without it.
## 2. [DotQueryServer] (DQP), which binds first so that it owns the socket when the
##    two share one.
## 3. [DotA2SServer], which either takes that socket over from DQP or binds its own.
##
## [b]One socket or two, and one port or two.[/b] The two protocols are told apart
## by their first four bytes — [code]FF FF FF FF[/code] is A2S, [code]DQP1[/code]
## is not — so both can answer on the game port, which is the only port a tracker
## will try. Give them different ports and they bind separately; give them the same
## one and DQP binds it and hands A2S the datagrams that are A2S's. Neither
## arrangement changes a single byte of either protocol.
##
## [codeblock]
## var host := DotQueryHost.new()
## host.app_url = "arena"          # the app's URL segment on the website
## server.add_child(host)          # finds the server and attaches itself
## [/codeblock]

const CHANNEL := "query"
const SERVICE := &"dot_query_host"

## The server to answer for. Defaults to whichever one is in [DotRegistry].
##
## Explicit rather than assumed, because a project may run two servers in one
## process — which is what testing a listen server against a dedicated one means —
## and a host that grabbed "the" server would attach to whichever booted first.
@export var server_ref: DotNodeRef = null

## How long to wait for a server to appear in [DotRegistry] before giving up.
##
## Only used when [member server_ref] is the default registry lookup. A ref
## naming a path or a node resolves on the first try and never waits.
@export_range(0.0, 60.0, 0.5) var attach_timeout_sec: float = 10.0

## The app's URL segment on the website: this game's code name in a listing.
##
## Unique and lowercase because the website already made it so, which is the whole
## reason to reuse it rather than invent a second identifier that has to be kept in
## step. See [member DotQuerySource.app_url] for why nothing treats it as proof.
@export var app_url: String = ""

@export_group("Nodes")

## Where to find or create the snapshot builder. Created as a child by default.
@export var source_ref: DotNodeRef = null

## Where to find or create the DQP listener.
@export var query_ref: DotNodeRef = null

## Where to find or create the A2S listener.
@export var a2s_ref: DotNodeRef = null

## Where to find the dot-stats bridge. [b]Not created by default[/b] — a server
## whose game counts nothing should not grow a statistics section.
@export var stats_ref: DotNodeRef = null

signal opened(query_port: int, a2s_port: int)

var server: DotServer = null
var source: DotQuerySource = null
var query: DotQueryServer = null
var a2s: DotA2SServer = null
var stats: DotQueryStats = null

var _attached: bool = false
var _opened: bool = false


func _ready() -> void:
	if Engine.is_editor_hint():
		return

	if server_ref == null:
		server_ref = DotNodeRef.of_service(DotServer.SERVICE)

	# [b]A host is ready before the server beside it has booted.[/b] A server
	# registers itself part-way through boot(), so a host placed in the same
	# scene — the ordinary arrangement — looks for it and legitimately finds
	# nothing. Giving up there produces a server that comes up perfectly and
	# never answers a query, with nothing in the log to say why.
	#
	# Only the registry path waits. A ref naming a path or a node resolves on the
	# first try, and waiting on one that cannot appear later would just delay the
	# error by ten seconds.
	if server_ref.mode == DotNodeRef.Mode.REGISTRY \
			and DotRegistry.get_service(server_ref.service) == null:
		var waited := await DotRegistry.await_service(
			server_ref.service, attach_timeout_sec
		)
		if not waited.ok:
			DotLog.warn(
				CHANNEL,
				"no server to attach to: this server will not answer queries",
				{"service": String(server_ref.service)}
			)
			return

	var attached := attach()
	if not attached.ok:
		DotLog.warn(
			CHANNEL,
			"could not attach to the server",
			{"detail": attached.error.message}
		)


func _exit_tree() -> void:
	close()
	DotRegistry.unregister_instance(SERVICE, self)


# --- Attaching -------------------------------------------------------------

## Finds the server and offers itself to it.
##
## Safe to call twice. The server opens the listeners when it is ready to; a host
## added to a server that has already booted is opened immediately, which is what
## makes this work from a module loaded at runtime as well as from a scene.
func attach() -> DotResult:
	if _attached:
		return DotResult.success(server)

	if server_ref == null:
		server_ref = DotNodeRef.of_service(DotServer.SERVICE)

	var resolved := server_ref.resolve(self)
	if not resolved.ok:
		return resolved.wrap(
			"A query host needs a server. Point server_ref at one, or add this "
			+ "node after the server has registered itself."
		)

	server = resolved.value as DotServer
	if server == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "server_ref did not resolve to a DotServer."
		)

	DotRegistry.register(SERVICE, self)
	_attached = true

	# The server calls back into open() when it is ready, or straight away if it
	# already is. Duck-typed on its side, so this is the only place the two halves
	# have to agree on a name.
	return server.attach_query_host(self)


# --- Opening ---------------------------------------------------------------

## Brings up whichever listeners the configuration asks for.
##
## Called by the server. Returns success when nothing is enabled: a server with no
## query listener is a supported configuration, not a failure.
func open() -> DotResult:
	if _opened:
		return DotResult.success(self)
	if server == null:
		return DotResult.fail(DotError.CODE_STATE, "Not attached to a server.")

	var config := server.config
	if not config.query_enabled and not config.a2s_enabled:
		return DotResult.success(self)

	_opened = true

	var built := _build_source()
	if not built.ok:
		return built

	_register_console()

	var query_port := 0
	if config.query_enabled:
		query_port = _open_query(config)

	var a2s_port := _open_a2s(config)

	opened.emit(query_port, a2s_port)
	return DotResult.success(self)


func _build_source() -> DotResult:
	if source_ref == null:
		source_ref = DotNodeRef.of_created(&"QuerySource", DotQuerySource)

	var resolved := source_ref.resolve(self)
	if not resolved.ok:
		return resolved.wrap("Could not create the query source.")

	source = resolved.value as DotQuerySource
	if source == null:
		return DotResult.fail(
			DotError.CODE_INVALID, "source_ref did not resolve to a DotQuerySource."
		)

	source.app_url = app_url
	source.setup(server)

	if stats_ref != null:
		var stats_node := stats_ref.resolve_or_null(self, CHANNEL)
		stats = stats_node as DotQueryStats
		if stats != null:
			stats.setup(server)
			source.stats = stats

	# The server's own query_source hook, so DotModule.add_query_provider and the
	# builtin commands keep working exactly as they did when this lived inside
	# dot-server. Duck-typed on that side; a plain assignment on this one.
	server.query_source = source

	return DotResult.success(source)


func _open_query(config: DotServerConfig) -> int:
	if config.effective_query_port() <= 0:
		# A server with no fixed port (a peer-to-peer session) has nothing to
		# derive a query port from, and a listener on a port nobody was told about
		# is one nobody can find.
		DotLog.info(
			CHANNEL,
			"query listener disabled: set query_port, there is no fixed game port "
			+ "to derive one from"
		)
		return 0

	if query_ref == null:
		query_ref = DotNodeRef.of_created(&"Query", DotQueryServer)

	query = query_ref.resolve_or_null(self, CHANNEL) as DotQueryServer
	if query == null:
		return 0

	query.setup(server, source)

	var result := query.open()
	if not result.ok:
		DotLog.warn(
			CHANNEL,
			"could not open the query listener",
			{"detail": result.error.message}
		)
		return 0

	server.query = query
	return config.effective_query_port()


func _open_a2s(config: DotServerConfig) -> int:
	if not config.a2s_enabled:
		return 0

	if config.effective_a2s_port() <= 0:
		DotLog.info(
			CHANNEL,
			"A2S disabled: set a2s_port, there is no fixed game port to derive "
			+ "one from"
		)
		return 0

	if a2s_ref == null:
		a2s_ref = DotNodeRef.of_created(&"A2S", DotA2SServer)

	a2s = a2s_ref.resolve_or_null(self, CHANNEL) as DotA2SServer
	if a2s == null:
		return 0

	a2s.setup(server, source)
	server.a2s = a2s

	# One socket when the ports match: DQP already holds it and can tell an A2S
	# datagram from its own in four bytes, so binding a second one would fail
	# anyway. This is the arrangement that puts both protocols on the game port.
	var shared := query != null and query.is_listening() \
		and config.effective_query_port() == config.effective_a2s_port()

	if shared:
		query.attach_a2s(a2s)
		return config.effective_a2s_port()

	var result := a2s.open()
	if not result.ok:
		DotLog.warn(
			CHANNEL, "could not open the A2S listener", {"detail": result.error.message}
		)
		return 0

	return config.effective_a2s_port()


func close() -> void:
	if query != null:
		query.close()
	if a2s != null:
		a2s.close()
	_opened = false


func is_open() -> bool:
	return _opened


# --- Console ---------------------------------------------------------------

## Registers the query cvar and the two commands that report on this subsystem.
##
## They live here rather than in dot-server's builtin command table because the
## thing they describe lives here: a server without this addon should not offer a
## `query_status` that can only ever answer "no query listener".
func _register_console() -> void:
	var console := server.console
	if console == null:
		return

	console.cvar(
		"sv_query_app",
		app_url,
		"The app's URL segment, reported as the game's name in a listing.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)

	console.command(
		"query_status",
		func(ctx: DotCmdContext) -> void:
			ctx.reply("[dot query]")
			if query != null:
				ctx.reply_lines(query.describe_lines())
			else:
				ctx.reply("  not listening")

			ctx.reply("")
			ctx.reply("[a2s]")
			if a2s != null:
				ctx.reply_lines(a2s.describe_lines())
			else:
				ctx.reply("  disabled")

			if stats != null:
				ctx.reply("")
				ctx.reply("[stats]")
				ctx.reply_lines(stats.describe_lines())

			ctx.reply("")
			ctx.reply("[snapshot]")
			ctx.reply_lines(source.describe_lines()),
		"Show the query listeners and the snapshot they serve."
	)

	console.command(
		"query_dump",
		func(ctx: DotCmdContext) -> void:
			# Forced, so an operator checking what a provider contributes sees the
			# current answer rather than one cached up to a second ago — which is
			# exactly the difference they are looking at.
			var snap := source.snapshot(true)
			ctx.reply(JSON.stringify(snap.to_full_dict(), "  ")),
		"Print the full query response, as a querier would receive it.",
		DotAdminFlags.GENERIC
	)


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"attached": _attached,
		"open": _opened,
		"app": source.effective_app_url() if source != null else app_url,
		"query": query != null and query.is_listening(),
		"a2s": a2s != null,
		"shared_socket": query != null and a2s != null and not a2s.is_listening(),
		"stats": stats != null,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if not _attached:
		out.append("not attached to a server")
		return out

	out.append("app         %s" % (
		source.effective_app_url() if source != null else app_url
	))
	out.append("dqp         %s" % (
		"listening" if query != null and query.is_listening() else "off"
	))
	out.append("a2s         %s" % _a2s_line())
	out.append("stats       %s" % ("attached" if stats != null else "none"))
	return out


func _a2s_line() -> String:
	if a2s == null:
		return "off"
	if a2s.is_listening():
		return "listening on its own socket"
	return "sharing the dot query socket"
