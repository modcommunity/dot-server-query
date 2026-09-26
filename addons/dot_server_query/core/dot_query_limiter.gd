class_name DotQueryLimiter
extends DotRateLimiter

## dot-core's per-key token bucket, with a ceiling on how many keys it will hold.
##
## [b]Why the query listeners cannot use [DotRateLimiter] as it is.[/b] Both of them
## rate-limit by source address [i]before[/i] the challenge, which is the right order —
## the limit is what bounds the HMAC work a flood costs — but it means the key is a UDP
## source address nobody has proved. Forging one costs nothing, so every forged datagram
## was a new bucket. And the base class's sweep compares the token count [i]as last
## stored[/i] with the burst, so a key that sent a single packet stored `burst - 1` and
## was never evicted at all. A spoofed flood grew the table by one entry per packet for
## the life of the process, and every thirty seconds the sweep walked all of it on the
## main thread. That is the memory-exhaustion target DotQueryChallenge exists to refuse
## to be, rebuilt one layer in front of it.
##
## Two changes, and neither alters what a caller sees in the ordinary case:
##
## - [b]A full bucket is dropped, whatever its idle time.[/b] A bucket that has refilled
##   behaves exactly like one that does not exist, so evicting it loses nothing. The
##   base class waits for an idle timeout only because it cannot tell a refilled bucket
##   from a throttled one; this one does the arithmetic.
## - [b]Past [member max_tracked] keys, an unknown address shares one bucket.[/b] Refusing
##   it outright would let a spoofed flood lock every new querier out until the table
##   drained; giving it a fresh bucket each time is the unbounded table again. One shared
##   bucket at the configured rate keeps a trickle of answers going and costs one entry.
##   Addresses already in the table keep their own buckets throughout.

## Addresses held before new ones share [constant OVERFLOW_KEY]. Far more distinct
## queriers inside one refill period (burst / rate, five seconds shipped) than a listed
## server sees, and a bounded few megabytes however the table is filled.
const DEFAULT_MAX_TRACKED := 16384

## The key every address shares once the table is full. An int, where every address is a
## String, so no querier can land in it by name — and not a string with a NUL in it, which
## is what this was first: the parser replaces the NUL and says so on every parse of every
## project that links this addon, which a parse guard reads as a failure.
const OVERFLOW_KEY := -1

## Sweeps no more than this often, so a flood cannot make every packet walk the table.
const SWEEP_INTERVAL_MS := 1000

var max_tracked: int = DEFAULT_MAX_TRACKED

var _overflowed: int = 0
var _last_full_sweep_ms: int = -SWEEP_INTERVAL_MS


func allow(key: Variant, cost: float = 1.0) -> bool:
	if not _buckets.has(key) and _buckets.size() >= max_tracked:
		_sweep_refilled()

		if _buckets.size() >= max_tracked:
			_overflowed += 1
			return super.allow(OVERFLOW_KEY, cost)

	return super.allow(key, cost)


## Drops every bucket that has refilled. Lossless: see the class description.
func _sweep_refilled() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_full_sweep_ms < SWEEP_INTERVAL_MS:
		return
	_last_full_sweep_ms = now

	var dead: Array = []
	for key: Variant in _buckets:
		var entry: Array = _buckets[key]
		var elapsed := float(now - int(entry[1])) / 1000.0
		if float(entry[0]) + elapsed * rate >= burst - 0.001:
			dead.append(key)

	for key: Variant in dead:
		_buckets.erase(key)


## How many times an address was sent to the shared bucket because the table was full.
func overflowed() -> int:
	return _overflowed


func describe() -> Dictionary:
	var d := super.describe()
	d["max_tracked"] = max_tracked
	d["overflowed"] = _overflowed
	return d
