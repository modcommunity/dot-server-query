# Exposure

A query responder is a UDP service anyone on the internet can talk to without a connection. This is what keeps that safe and cheap.

## One socket or two, and why one is the point

The two protocols are told apart by their first four bytes (`FF FF FF FF` is A2S, `DQP1` is not), so both can answer on one UDP port. That is not a trick worth admiring for its own sake: **the game port is the only port a tracker will try**, and two listeners cannot bind one UDP port.

So `DotQueryServer` binds and `DotA2SServer` attaches to it, sharing one challenge secret so `query_status` shows one window rather than two that expire at different times. Different ports and they bind separately; `DotA2SServer.open()` is the path that is not taken when they share.

**When the game's transport already owns the UDP port** (ENet behind dot-server's demux, the dual-stack default), neither listener binds: each registers on the server with `share_udp_port(port, claims, handler)` and answers the datagrams its claim test accepts. The claim test runs on every ENet packet too, so the cheap byte test goes first. `close()` calls `unshare_udp_port`. Only when the port is held by something that will not share does the bind fail, and `_bind_advice` then says so, plus the part an operator needs to hear: set a different port, and know most trackers will not look there.

## The challenge is the reason this is safe to expose

UDP source addresses are forged trivially and a query is a small request producing a large response: the exact shape of a DDoS amplifier. Send a 30-byte packet with a victim's address in the source field and an unprotected server mails the victim a kilobyte. A2S ran that way for fifteen years.

- An unchallenged request is answered with **a cookie and nothing else**, and that reply is smaller than the request that provoked it.
- The cookie is `HMAC(secret, address|port|bucket|width)`, **bound to the address and port it was mailed to**. A forger never receives it, so it can never present one.
- **Nothing is stored.** A challenge table is itself a memory-exhaustion target: ask for a million challenges from a million forged addresses and the server holds them all. This holds one 32-byte secret regardless. Same reasoning as a SYN cookie.
- The previous time bucket is accepted as well, so the real window is one to two TTLs. Without that, a cookie issued a millisecond before a boundary is refused by the time it comes back, and a querier one RTT away can never succeed at all: a bug that only appears under load and looks like packet loss.
- The secret is generated at boot and never persisted. A restart invalidates every outstanding cookie, which is correct: a restart invalidated everything else a querier knew too.
- **A response arriving on the listening socket is never answered.** That is how two servers become a reflection loop.

`PING` is answered without a challenge, because `PONG` is smaller than the request. There is nothing to amplify.

**The WebSocket path has no challenge, and that is not an oversight.** The cookie proves a UDP source address is real; a WebSocket has completed a TCP handshake and an HTTP upgrade, so the transport already proved it, and the response goes back down the same connection where it cannot be aimed at anybody else.

## The rate limiter is bounded too

Both listeners limit by source address before the HMAC, which is the right order, but that key is an address nobody has proved. dot-core's `DotRateLimiter` kept one bucket per key and its sweep never evicted a key that had sent one packet, so a spoofed flood grew the table by one entry per datagram for the life of the process.

`DotQueryLimiter` (the subclass both listeners use) drops refilled buckets (lossless: a refilled bucket is no bucket) and, past `max_tracked` (16,384) addresses, sends unknown ones to one shared bucket rather than refusing them, so a flood cannot lock new queriers out either. `describe()` reports it under `limiter`.

## The snapshot cache is a security control, not an optimisation

Gathering a snapshot walks every session, every cvar and every provider. Doing that per packet is the cheapest denial of service there is, and unlike a flood of game traffic it does not even need a connection. `query_cache_sec` (1 s) puts a ceiling on it: a thousand queries a second cost one rebuild and a thousand serialisations of a dictionary that already exists.

## What A2S publishes

**A2S publishes player names, scores and connection times to anyone who asks, and always has.** `query_player_detail` governs it here too, and dot-server logs once at boot when A2S is on with `full`: an operator who turned A2S on to be listed may not have meant to publish a roster.
