class_name DotQueryLimiter
extends DotRateLimiter

## dot-core's per-key token bucket, with a ceiling on how many keys it will hold.
## Limiting by unproven UDP address would let forged ones grow the table without bound, so full buckets are
## dropped and past [member max_tracked] keys unknown addresses share one bucket.

## Addresses held before new ones share [constant OVERFLOW_KEY]. Far more distinct
## queriers inside one refill period (burst / rate, five seconds shipped) than a listed
## server sees, and a bounded few megabytes however the table is filled.
const DEFAULT_MAX_TRACKED := 16384

## The key every address shares once the table is full. An int, so no String address can land in it by name.
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
