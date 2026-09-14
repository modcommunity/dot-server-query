# dot-server-query

The server's side of a server query: the dot query protocol (DQP) and the whole of A2S, answered from one snapshot, on one socket or two.

**The distributable is `addons/dot_server_query/`.** It requires [dot-core](../dot-core) and [dot-server](../dot-server), and optionally bridges [dot-stats](../dot-stats) — which is discovered at runtime and named nowhere in the source.

```bash
# Local development setup — these symlinks are gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
ln -s ../../dot-server/addons/dot_server addons/dot_server

# Optional, and the self-test wants it: the dot-stats bridge is duck-typed, and
# linking the real addon is what checks the shape against the thing it describes
# rather than against a mock of it.
ln -s ../../dot-stats/addons/dot_stats addons/dot_stats
```

## This was inside dot-server until it wasn't

Everything here lived in `dot-server/addons/dot_server/query/` and was moved out whole — the protocols, the snapshot, the challenge, the provider API, the two console commands and the entire self-test. Nothing about either wire format changed in the move.

**It moved because answering a query is a concern most servers never switch on**, and because it is large: two protocols, a challenge scheme, a rate limiter and a WebSocket listener is more code than several addons in this family have in total. A server that will never be listed anywhere should not carry it.

**The direction of the dependency is the whole design.** dot-server-query names `DotServer`, `DotServerConfig`, `DotClientSession` and `DotConVar` freely — a query responder without a server is meaningless, so a hard dependency there costs nothing. dot-server names **nothing** here. It holds one hook:

```gdscript
func attach_query_host(host: Object) -> DotResult
```

`query_host`, `query_source`, `query` and `a2s` on `DotServer` are all typed `Object` and reached with `.call(...)`. That is not fussiness: **a script mentioning a `class_name` the project does not have fails to parse and takes every script referencing it down with it.** `DotQueryHost` named once in dot-server would make this repository mandatory for anything that so much as boots a server. Same reasoning as `DotChatRelay` in dot-server and `DotWeaponLoadoutBridge` in dot-weapon.

**The configuration stayed in dot-server.** `query_enabled`, `a2s_enabled`, `query_port`, `a2s_port`, `query_bind_address`, `query_player_detail`, `query_secret` and the rest are still `DotServerConfig` fields, and `sv_query`, `sv_a2s` and `sv_query_players` are still registered there before `server.cfg` runs. They are plain bools, ints and strings naming no class, so every operator's `server.yml` keeps working and the layering promise is unbroken. Moving them would have broken every deployment's config file to no purpose. New settings that only exist here — the app slug, the A2S extra-data fields, what the stats bridge publishes — are exports on the nodes instead.

## The boot handshake, in both directions

A host can be ready before its server, or after it. Both happen, and both had to work:

```
host._ready()  ->  server not registered yet  ->  await_service("dot_server")
                                              ->  attach_query_host(self)
                                              ->  server is IDLE, stored
server.boot()  ->  ... listener opens ... RUNNING
                                              ->  _open_query_host()
```

```
server.boot()  ->  RUNNING, no host attached, nothing happens
host._ready()  ->  attach_query_host(self)
                                              ->  server is RUNNING, open() now
```

**The first case is the ordinary one and it is the one that would have been missed.** A host placed in a scene beside a server is ready *before* that server has booted, and a server registers itself part-way through `boot()` — so the first lookup legitimately finds nothing. Giving up there produces a server that comes up perfectly and never answers a query, with nothing in the log to say why. `DotQueryHost._ready` waits, and only on the registry path: a ref naming a path or a node resolves on the first try, and waiting on one that cannot appear later would just delay the error by ten seconds.

Both orders are in the suite. `game-arena` uses a path ref and attaches before boot; `game-g2gfast` uses the registry default and attaches after.

## One socket or two, and why one is the point

The two protocols are told apart by their first four bytes — `FF FF FF FF` is A2S, `DQP1` is not — so both can answer on one UDP port. That is not a trick worth admiring for its own sake: **the game port is the only port a tracker will try**, and two listeners cannot bind one UDP port.

So `DotQueryServer` binds and `DotA2SServer` attaches to it, sharing one challenge secret so `query_status` shows one window rather than two that expire at different times. Different ports and they bind separately; `DotA2SServer.open()` is the path that is not taken when they share.

**A UDP game transport (ENet) already holds the game port.** The bind fails and `_bind_advice` says exactly that, plus the part an operator needs to hear: set a different port, and know most trackers will not look there.

## The challenge is the reason this is safe to expose

UDP source addresses are forged trivially and a query is a small request producing a large response — the exact shape of a DDoS amplifier. Send a 30-byte packet with a victim's address in the source field and an unprotected server mails the victim a kilobyte. A2S ran that way for fifteen years.

- An unchallenged request is answered with **a cookie and nothing else**, and that reply is smaller than the request that provoked it.
- The cookie is `HMAC(secret, address|port|bucket|width)`, **bound to the address and port it was mailed to**. A forger never receives it, so it can never present one.
- **Nothing is stored.** A challenge table is itself a memory-exhaustion target: ask for a million challenges from a million forged addresses and the server holds them all. This holds one 32-byte secret regardless. Same reasoning as a SYN cookie.
- The previous time bucket is accepted as well, so the real window is one to two TTLs. Without that, a cookie issued a millisecond before a boundary is refused by the time it comes back, and a querier one RTT away can never succeed at all — a bug that only appears under load and looks like packet loss.
- The secret is generated at boot and never persisted. A restart invalidates every outstanding cookie, which is correct: a restart invalidated everything else a querier knew too.
- **A response arriving on the listening socket is never answered.** That is how two servers become a reflection loop.

`PING` is answered without a challenge, because `PONG` is smaller than the request. There is nothing to amplify.

**The WebSocket path has no challenge, and that is not an oversight.** The cookie proves a UDP source address is real; a WebSocket has completed a TCP handshake and an HTTP upgrade, so the transport already proved it, and the response goes back down the same connection where it cannot be aimed at anybody else.

## The snapshot cache is a security control, not an optimisation

Gathering a snapshot walks every session, every cvar and every provider. Doing that per packet is the cheapest denial of service there is, and unlike a flood of game traffic it does not even need a connection. `query_cache_sec` (1s) puts a ceiling on it: a thousand queries a second cost one rebuild and a thousand serialisations of a dictionary that already exists.

## Sections, and the two rules about the revision

`info`, `players`, `rules`, `game`, `teams`, `rotation`, `perf`, `build`, `stats`, `player_stats`.

Every one is built on every rebuild. **An earlier draft built the expensive ones only when asked for, and that was wrong**: the revision is derived from a hash of the content, so a snapshot built without `teams` and one built with it would hash differently, and two queriers asking for different sections would be told different revisions for the same server state. Conditional polling would then be worse than useless — it would report changes that had not happened. Build everything, hash everything, and the revision means one thing.

The exception is the second rule. **`perf` is excluded from the hash** (`DotQuerySnapshot.VOLATILE_SECTIONS`), because every field in it — frame time, memory, fps — differs on every rebuild. Hashing it would mint a new revision every second and `if_rev` would never once save a byte. `info.uptime` and per-player `duration` and `ping` are erased before hashing for the same reason, and were already.

`teams` is read duck-typed from whatever registered as `dot_team_roster`, so dot-team is not named here either; a game with no teams gets an empty section rather than a parse failure.

## `info.signon` is the field a browser needs before it connects

The RPC surface both ends of a join have to agree on, as twelve characters — `DotSignon.revision([DotServer, DotChatManager])`, derived from the `@rpc` method names Godot itself checksums. See dot-server's CLAUDE.md for why that comparison exists and what it looks like when it fails.

**It is in `info` rather than in `rules`, and that is the whole point of putting it here at all.** A client whose build declares a different set of those methods cannot complete a join with this server: Godot refuses to confirm the path, the connection opens and then goes quiet, and the player is eventually told they timed out. The only way to spare them that is to know *before connecting* — which means the answer has to be in the cheapest section, the one a listing already fetches for every row, not in the one you get after clicking a server.

That is what makes "this server needs a different build, open that one" possible for a server browser or a web loader. Without it the only way to discover a mismatch is to suffer it.

It is a normal hashed field: it changes only when the addon's RPC surface changes, which is rare, so it costs conditional polling nothing.

## The app slug is display-only and says so everywhere

`info.app` — and A2S's `folder`, because that field has always been the short lowercase name a tracker groups servers by, and having the two disagree is how one server appears twice in a list.

It is the app's **URL segment on the website**: unique, lowercase and already maintained there, which is the whole reason to reuse it rather than invent a second identifier that has to be kept in step.

**A server can claim any app it likes, and that is fine.** Nothing that has to be certain which app a server belongs to reads this: a launch resolving a build and a play grant both ask the backbone, which knows (`server.appId === app.id`). This is what a listing prints next to the hostname. Writing that down matters more than the field does, because the failure mode is somebody downstream deciding to trust it.

`a2s_game_folder` still wins when an operator has changed it from the shipped default `"dot"` — they meant it. The default is the same string on every server in the family, which makes it useless as a grouping key, so that one case hands the folder to the app slug.

## The dot-stats bridge, and the join that cannot be guessed

`DotQueryStats` answers three different questions, which is the split a querier actually wants: what this **server** has done since it booted, the published stats totalled across everyone on it (**game**), and one row per **player**.

The first two identify nobody and are on by default. The third is off, and **a boolean is not enough to turn it on**.

**Why:** a game chooses its own key for a stats player and nothing in dot-stats records which. This family alone uses `arena-player-%08d`, a bare userid and a per-account string. There is no way to map a connected session to its statistics from here, so `player_key_format` (a printf over the session's userid) or a duck-typed resolver is required as well. Getting it wrong does not throw — it matches nobody and publishes an empty section, which reads as "nobody has done anything" rather than as a misconfiguration, so the host warns at boot when `publish_players` is on with no way to honour it.

**The key is never published.** It is matched against and discarded; rows carry the display name and userid the player list already carries. A game keying statistics by account uid would otherwise publish that uid to anyone who sends a datagram — and dot-user's whole point is that an operator cannot correlate players across servers. Undoing that from the query side is no better than undoing it from the login side.

Only stats flagged `publish` in the schema appear, on both the totals and the per-player path. dot-stats already draws that line for the backbone report and it is the right line here: a stat a game keeps private from its own backend has no business going out over UDP.

## A2S: all of it, and the two parts deliberately missing

Every request the protocol defines — `A2S_INFO`, `A2S_PLAYER`, `A2S_RULES`, `A2S_SERVERQUERY_GETCHALLENGE`, `A2A_PING` — and every extra-data field.

**The extra-data fields must be written in the protocol's field order, not the numeric order of the bits**: port (`0x80`), server id (`0x10`), spectator pair (`0x40`), keywords (`0x20`), game id (`0x01`). A reader walks them in that sequence and has no way to detect a writer that chose a different one — it reads a port out of the middle of a string. The three constants for these existed and were never emitted before this addon; the suite now reads every one of them back.

`steam_id`, `spectator_port` and `game_id` are 0 and absent unless an operator sets them. **There is no platform identity behind this family, and a fabricated one is a lie a client acts on** — a client reading a server id expects to be able to ask that platform about it. Absent is honest; invented is not.

The one game-specific block the protocol carries is gated on `a2s_app_id` falling in a closed published range, so it can never fire by accident. It sits **before the version string**, not in the extra data, and a client for one of those app ids reads it unconditionally — so emitting it for any other id shifts every following field and produces a response that parses into nonsense rather than one that visibly fails. The matching per-player pair in `A2S_PLAYER` is written whether or not a provider filled it in, for the same reason: an absent block is not an empty one, it is a truncated response.

**Not here, on purpose:** split responses are never compressed (the compressed form is bzip2, the engine ships none, and the flag is optional — a client that never sees it set never needs one), and the older engine branch's split header is not emitted (it differs in layout and is told apart by nothing in the packet; every client of the last fifteen years reads the format this sends).

**A2S publishes player names, scores and connection times to anyone who asks, and always has.** `query_player_detail` governs it here too, and dot-server logs once at boot when A2S is on with `full` — an operator who turned A2S on to be listed may not have meant to publish a roster.

## Bugs found by running this, not by reading it

The two from the original implementation, both parse-clean, are still worth knowing because both are easy to reintroduce:

- **One flag bit with two meanings.** `FLAG_GZIP` meant "I accept gzip" on a request and "this is gzipped" on a response, on the reasoning that a request is never compressed so the bit was free. It made the header un-parseable without already knowing the direction: the parser reads the header to find that out, so it tried to gunzip a plaintext request body and failed. Every query was silently dropped. `FLAG_ACCEPT_GZIP` is its own bit now.
- **A fragment is not independently decodable.** `parse()` gunzipped and JSON-parsed whatever payload it was handed, so reading a fragment's header — exactly what reassembly does first — logged two engine errors on a completely normal path. Nothing failed; it just looked broken in every log it appeared in.

And one from the extraction itself, which the suite caught immediately: **the A2S `folder` field stopped being the configured string and became the app slug**, so an assertion inherited from dot-server's example failed. That was the intended change, but it is a wire-visible one — a tracker grouping servers by folder sees them regroup.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done

# 164 checks. Exits non-zero on any failure.
godot --headless --path . res://examples/query_selftest.tscn

# Run it as an actual server instead of self-testing:
godot --headless --path . res://examples/query_selftest.tscn -- --serve
```

**Both protocols are driven without a socket.** `handle_datagram` takes a datagram and returns the datagrams to send back, so the whole of DQP and A2S runs in process — which also means it is tested on a machine where binding is refused. The listeners still bind for real in the example, so the shared-socket path is exercised rather than assumed.

**Changing this addon means re-running dot-server's suite too**, and `game-arena`'s and `game-g2gfast`'s: arena asks its own server over a real UDP socket through dot-browser, and g2gfast asserts what its module contributes.

```bash
cd ../dot-server      && godot --headless --path . res://examples/dedicated_server.tscn   # 224
cd ../game-arena      && godot --headless --path . res://examples/dedicated.tscn          # 91
cd ../game-g2gfast    && godot --headless --path . res://examples/dedicated.tscn          # 129
```

## File map

```
addons/dot_server_query/
  PROTOCOL.md                The wire spec. Enough to write a client in any language.
  host/
    dot_query_host.gd        The whole integration: finds a server, fills its hook,
                             owns the listeners, registers the two commands.
  core/
    dot_query_challenge.gd   Stateless address-bound cookies. The anti-amplifier.
    dot_query_snapshot.gd    What the server looks like from outside, at one moment.
    dot_query_provider.gd    Where a game contributes its own state.
  source/
    dot_query_source.gd      Builds and caches the snapshot; holds the providers.
  dqp/
    dot_query_protocol.gd    DQP framing: header, flags, fragments, gzip.
    dot_query_server.gd      DQP over UDP, and over WebSocket for browsers.
  a2s/
    dot_a2s_server.gd        A2S, all of it. Compatibility, and off by default.
  stats/
    dot_query_stats.gd       The dot-stats bridge. Names no DotStats* identifier.
```

## Things deliberately not here

- **A query client.** This answers and does not ask. [dot-browser](../dot-browser) is the client half, and it is a **second implementation** of the wire format on purpose — its self-test checks it against bytes this encoder produced rather than against itself.
- **Delta responses.** `if_rev` answers "unchanged" or resends the whole thing. A patch between two revisions would be smaller again and is not worth the complexity until something is polling enough servers to notice.
- **A master-server heartbeat.** Nothing announces a server anywhere; a tracker has to be told the address. Both protocols answer once it has been. `sv_lan` lives in dot-server and still does nothing.
- **Signing on by default.** `query_secret` enables an HMAC over the response body, for a listing service that must know the server really said this rather than somebody forging a busy server to climb a list. Off unless set: a signature nobody checks is cost with no benefit.
