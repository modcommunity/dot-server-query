@tool
extends EditorPlugin

## Editor entry point for dot-server-query. Registers inspector types only.
##
## No autoloads: a project may run a server and a client in one process, and two
## servers in one editor session, and a singleton would make both impossible. The
## host places [DotQueryHost] itself and points it at a server with a [DotNodeRef].

const _ICON := "res://addons/dot_server_query/icon_placeholder.svg"

const _TYPES := [
	["DotQueryHost", "Node", "res://addons/dot_server_query/host/dot_query_host.gd"],
	["DotQuerySource", "Node", "res://addons/dot_server_query/source/dot_query_source.gd"],
	["DotQueryServer", "Node", "res://addons/dot_server_query/dqp/dot_query_server.gd"],
	["DotA2SServer", "Node", "res://addons/dot_server_query/a2s/dot_a2s_server.gd"],
	["DotQueryStats", "Node", "res://addons/dot_server_query/stats/dot_query_stats.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	# Reversed so a type is never removed before something that referenced it,
	# which matters when the editor reloads the plugin.
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
