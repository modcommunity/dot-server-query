class_name DotQueryProvider
extends RefCounted

## Where a game puts its own state into a query response. Subclass, override [code]_provider_name()[/code] and [code]_contribute(snapshot)[/code], and register with
## [method DotQuerySource.add_provider]. It runs on the public query path once per rebuild: keep it cheap.
## Any object with [code]_contribute[/code] (or [code]contribute[/code]) and a name works.


## Identifier shown in `query_status` and the key to remove the provider again.
func _provider_name() -> String:
	return "provider"


## Adds to, or corrects, the snapshot. Called after the standard sections are built.
func _contribute(_snapshot: DotQuerySnapshot) -> void:
	pass


## Checks an object can act as a provider, before it is registered.
static func validate(provider: Object) -> DotResult:
	if provider == null:
		return DotResult.fail(DotError.CODE_INVALID, "A provider cannot be null.")

	if not (provider.has_method("_contribute") or provider.has_method("contribute")):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A query provider needs a _contribute(snapshot) method.",
			"got a %s" % provider.get_class()
		)

	return DotResult.success(provider)


static func name_of(provider: Object) -> String:
	if provider == null:
		return ""
	if provider.has_method("_provider_name"):
		return str(provider.call("_provider_name"))
	if provider.has_method("provider_name"):
		return str(provider.call("provider_name"))
	if provider is Node:
		return str((provider as Node).name)
	return provider.get_class()


static func contribute_to(provider: Object, snapshot: DotQuerySnapshot) -> void:
	if provider == null:
		return
	if provider.has_method("_contribute"):
		provider.call("_contribute", snapshot)
		return
	if provider.has_method("contribute"):
		provider.call("contribute", snapshot)
