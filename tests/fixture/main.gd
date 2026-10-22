extends Node2D

# Prints so the e2e can assert that `gdcli game logs` captures real game output.
func _ready() -> void:
	print("fixture: main scene ready")
	printerr("fixture: stderr line")
