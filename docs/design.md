# Design

Where this addon sits, how it attaches to a server, and what a snapshot contains. The listening side (sockets, the challenge, the cache) is [exposure.md](exposure.md); A2S's wire rules are [a2s.md](a2s.md).

## Why it is its own addon

Everything here lived in `dot-server/addons/dot_server/query/` and was moved out whole: the protocols, the snapshot, the challenge, the provider API, the two console commands and the entire self-test. Nothing about either wire format changed in the move.

**It moved because answering a query is a concern most servers never switch on**, and because it is large: two protocols, a challenge scheme, a rate limiter and a WebSocket listener is more code than several addons in this family have in total. A server that will never be listed anywhere should not carry it.

## The direction of the dependency is the whole design

dot-server-query names `DotServer`, `DotServerConfig`, `DotClientSession` and `DotConVar` freely: a query responder without a server is meaningless, so a hard dependency there costs nothing. dot-server names **nothing** here. It holds one hook:

```gdscript
func attach_query_host(host: Object) -> DotResult
```

`query_host`, `query_source`, `query` and `a2s` on `DotServer` are all typed `Object` and reached with `.call(...)`. That is not fussiness: **a script mentioning a `class_name` the project does not have fails to parse and takes every script referencing it down with it.** `DotQueryHost` named once in dot-server would make this repository mandatory for anything that so much as boots a server. Same reasoning as `DotChatRelay` in dot-server and `DotWeaponLoadoutBridge` in dot-weapon.

**The configuration stayed in dot-server.** `query_enabled`, `a2s_enabled`, `query_port`, `a2s_port`, `query_bind_address`, `query_player_detail`, `query_secret` and the rest are still `DotServerConfig` fields, and `sv_query`, `sv_a2s` and `sv_query_players` are still registered there before `server.cfg` runs. They are plain bools, ints and strings naming no class, so every operator's `server.yml` keeps working and the layering promise is unbroken. Moving them would have broken every deployment's config file to no purpose. New settings that only exist here (the app slug, the A2S extra-data fields, what the stats bridge publishes) are exports on the nodes instead.

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

**The first case is the ordinary one and it is the one that would have been missed.** A host placed in a scene beside a server is ready *before* that server has booted, and a server registers itself part-way through `boot()`, so the first lookup legitimately finds nothing. Giving up there produces a server that comes up perfectly and never answers a query, with nothing in the log to say why. `DotQueryHost._ready` waits, and only on the registry path: a ref naming a path or a node resolves on the first try, and waiting on one that cannot appear later would just delay the error by ten seconds.

Both orders are in the suite. `game-arena` uses a path ref and attaches before boot; `game-g2gfast` uses the registry default and attaches after.

## Sections, and the two rules about the revision

`info`, `players`, `rules`, `game`, `teams`, `rotation`, `perf`, `build`, `stats`, `player_stats`.

Every one is built on every rebuild. **An earlier draft built the expensive ones only when asked for, and that was wrong**: the revision is derived from a hash of the content, so a snapshot built without `teams` and one built with it would hash differently, and two queriers asking for different sections would be told different revisions for the same server state. Conditional polling would then be worse than useless: it would report changes that had not happened. Build everything, hash everything, and the revision means one thing.

The exception is the second rule. **`perf` is excluded from the hash** (`DotQuerySnapshot.VOLATILE_SECTIONS`), because every field in it (frame time, memory, fps) differs on every rebuild. Hashing it would mint a new revision every second and `if_rev` would never once save a byte. `info.uptime` and per-player `duration` and `ping` are erased before hashing for the same reason.

`teams` is read duck-typed from whatever registered as `dot_team_roster`, so dot-team is not named here either; a game with no teams gets an empty section rather than a parse failure.

## `info.signon` is the field a browser needs before it connects

The RPC surface both ends of a join have to agree on, as twelve characters: `DotSignon.revision([DotServer, DotChatManager])`, derived from the `@rpc` method names Godot itself checksums. dot-server's [CLAUDE.md](../../dot-server/CLAUDE.md) explains why that comparison exists and what it looks like when it fails.

**It is in `info` rather than in `rules`, and that is the whole point of putting it here at all.** A client whose build declares a different set of those methods cannot complete a join with this server: Godot refuses to confirm the path, the connection opens and then goes quiet, and the player is eventually told they timed out. The only way to spare them that is to know *before connecting*, which means the answer has to be in the cheapest section, the one a listing already fetches for every row, not in the one you get after clicking a server. That is what makes "this server needs a different build, open that one" possible for a server browser or a web loader.

It is a normal hashed field: it changes only when the addon's RPC surface changes, which is rare, so it costs conditional polling nothing.

`info.enet_port` is set when the server's transport also listens on ENet (dual stack), so a native client learns it can join over UDP; A2S carries the same fact as a `udp:<port>` keyword.

## The app slug is display-only and says so everywhere

`info.app`, and A2S's `folder`, because that field has always been the short lowercase name a tracker groups servers by, and having the two disagree is how one server appears twice in a list.

It is the app's **URL segment on the website**: unique, lowercase and already maintained there, which is the whole reason to reuse it rather than invent a second identifier that has to be kept in step.

**A server can claim any app it likes, and that is fine.** Nothing that has to be certain which app a server belongs to reads this: a launch resolving a build and a play grant both ask the backbone, which knows (`server.appId === app.id`). This is what a listing prints next to the hostname. Writing that down matters more than the field does, because the failure mode is somebody downstream deciding to trust it.

`a2s_game_folder` still wins when an operator has changed it from the shipped default `"dot"`: they meant it. The default is the same string on every server in the family, which makes it useless as a grouping key, so that one case hands the folder to the app slug.

## The dot-stats bridge, and the join that cannot be guessed

`DotQueryStats` answers three different questions, which is the split a querier actually wants: what this **server** has done since it booted, the published stats totalled across everyone on it (**game**), and one row per **player**.

The first two identify nobody and are on by default. The third is off, and **a boolean is not enough to turn it on**.

**Why:** a game chooses its own key for a stats player and nothing in dot-stats records which. This family alone uses `arena-player-%08d`, a bare userid and a per-account string. There is no way to map a connected session to its statistics from here, so `player_key_format` (a printf over the session's userid) or a duck-typed resolver is required as well. Getting it wrong does not throw: it matches nobody and publishes an empty section, which reads as "nobody has done anything" rather than as a misconfiguration, so the host warns at boot when `publish_players` is on with no way to honour it.

**The key is never published.** It is matched against and discarded; rows carry the display name and userid the player list already carries. A game keying statistics by account uid would otherwise publish that uid to anyone who sends a datagram, and dot-user's whole point is that an operator cannot correlate players across servers. Undoing that from the query side is no better than undoing it from the login side.

Only stats flagged `publish` in the schema appear, on both the totals and the per-player path. dot-stats already draws that line for the backbone report and it is the right line here: a stat a game keeps private from its own backend has no business going out over UDP.

## Deliberately not here

- **A query client.** This answers and does not ask. [dot-browser](../../dot-browser) is the client half, and it is a **second implementation** of the wire format on purpose: its self-test checks it against bytes this encoder produced rather than against itself.
- **Delta responses.** `if_rev` answers "unchanged" or resends the whole thing. A patch between two revisions would be smaller again and is not worth the complexity until something is polling enough servers to notice.
- **A master-server heartbeat.** Nothing announces a server anywhere; a tracker has to be told the address. Both protocols answer once it has been. `sv_lan` lives in dot-server and still does nothing.
- **Signing on by default.** `query_secret` enables an HMAC over the response body, for a listing service that must know the server really said this rather than somebody forging a busy server to climb a list. Off unless set: a signature nobody checks is cost with no benefit.
