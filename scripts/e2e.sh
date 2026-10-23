#!/usr/bin/env bash
# End-to-end check: install the plugin into a throwaway copy of tests/fixture, drive a real
# Godot editor over the wire, and assert the saved scene kept its instance relationship.
#
# Uses --headless for CI convenience only; the product path is a normal GUI editor.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-/tmp/gdcli-e2e}"
GODOT="${GODOT:-godot}"
BIN="$REPO/target/debug/gdcli"

fail() { echo "FAIL: $*" >&2; exit 1; }
step() { echo "--- $*"; }

step "build"
cargo build --manifest-path "$REPO/Cargo.toml" --quiet

step "fresh fixture in $WORK"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$REPO"/tests/fixture/project.godot "$REPO"/tests/fixture/*.tscn "$REPO"/tests/fixture/*.gd "$WORK"/
mkdir -p "$WORK/addons/probe"
printf '[plugin]\n\nname="probe"\ndescription="e2e probe plugin"\nversion="0.0.1"\nscript="plugin.gd"\n' >"$WORK/addons/probe/plugin.cfg"
printf '@tool\nextends EditorPlugin\n' >"$WORK/addons/probe/plugin.gd"

step "plugin install"
"$BIN" plugin install --project "$WORK" | sed 's/^/    /'
grep -q 'res://addons/gdcli/plugin.cfg' "$WORK/project.godot" || fail "project.godot not patched"

step "version consistency"
CLI_V="$("$BIN" --version | awk '{print $2}')"
CFG_V="$(sed -n 's/^version="\(.*\)"$/\1/p' "$WORK/addons/gdcli/plugin.cfg")"
[[ "$CLI_V" == "$CFG_V" ]] || fail "cli $CLI_V != installed plugin.cfg $CFG_V"
echo "    cli == plugin.cfg: $CLI_V"

step "start editor"
rm -f "$WORK/.godot/gdcli/endpoint.json"
"$GODOT" --headless --editor --path "$WORK" res://main.tscn >"$WORK/editor.log" 2>&1 &
EDITOR_PID=$!
trap 'kill "$EDITOR_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 120); do
	[[ -f "$WORK/.godot/gdcli/endpoint.json" ]] && break
	sleep 0.5
done
[[ -f "$WORK/.godot/gdcli/endpoint.json" ]] || { tail -20 "$WORK/editor.log"; fail "endpoint never appeared"; }

# The launch argument races the filesystem scan; open it explicitly so the first command
# always sees an edited scene.
"$BIN" scene open res://main.tscn --project "$WORK" | sed 's/^/    /'

step "status + tree"
"$BIN" editor status --project "$WORK" | sed 's/^/    /'
TREE="$("$BIN" scene tree --project "$WORK" --json)"
python3 - "$TREE" <<'PY'
import json, sys
nodes = json.loads(sys.argv[1])["nodes"]
by = {n["path"]: n for n in nodes}
assert "Inst" in by, by.keys()
assert by["Inst"]["instance"] == "res://sub.tscn", by["Inst"]
assert by["."]["children"] == 1, by["."]
print("    tree ok:", [n["path"] for n in nodes])
PY

step "version consistency (live)"
PING_V="$("$BIN" raw meta.ping --project "$WORK" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["plugin_version"])')"
[[ "$PING_V" == "$CLI_V" ]] || fail "live plugin $PING_V != cli $CLI_V"
echo "    cli == live plugin: $PING_V"

step "mutations"
"$BIN" node add Sprite2D --name Hero --project "$WORK" | sed 's/^/    /'
"$BIN" prop set Hero position 'Vector2(3, 4)' --project "$WORK" | sed 's/^/    /'
"$BIN" node dup Hero --name Hero2 --project "$WORK" | sed 's/^/    /'
"$BIN" node rename Hero2 Villain --project "$WORK" | sed 's/^/    /'
"$BIN" node mv Villain --to Inst --project "$WORK" | sed 's/^/    /'
"$BIN" prop get Hero position --quiet --project "$WORK" | sed 's/^/    /'

step "dry run leaves no trace"
"$BIN" node add Node2D --name Ghost --dry-run --project "$WORK" --json | sed 's/^/    /'
"$BIN" scene tree --project "$WORK" --json | python3 -c 'import json,sys; assert "Ghost" not in [n["name"] for n in json.load(sys.stdin)["nodes"]]' \
	|| fail "--dry-run mutated the scene"

step "errors"
set +e
"$BIN" prop set Hero nope 1 --project "$WORK" >/dev/null 2>"$WORK/err.txt"
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "bad property should exit 3, got $CODE: $(cat "$WORK/err.txt")"
"$BIN" raw meta.ping --project "$WORK" --quiet >/dev/null || fail "raw meta.ping failed"

step "batch"
printf '%s\n' \
	'{"cmd":"scene.tree","args":{}}' \
	'{"cmd":"prop.get","args":{"target":"Hero","name":"position"}}' \
	| "$BIN" batch --project "$WORK" | sed 's/^/    /'

step "save"
"$BIN" scene save --project "$WORK" | sed 's/^/    /'

step "assert saved scene"
cat "$WORK/main.tscn" | sed 's/^/    /'
python3 - "$WORK/main.tscn" <<'PY'
import sys
text = open(sys.argv[1]).read()
checks = {
    'Hero node': '[node name="Hero" type="Sprite2D" parent="."',
    'Hero position': 'position = Vector2(3, 4)',
    'Villain under Inst': '[node name="Villain" type="Sprite2D" parent="Inst"',
    'instance kept': 'instance=ExtResource("1_sub")',
    'instance override kept': 'position = Vector2(10, 20)',
}
missing = [k for k, v in checks.items() if v not in text]
if missing:
    raise SystemExit("missing from saved scene: %s" % missing)
print("    scene assertions ok:", ", ".join(checks))
PY

step "undo / redo"
"$BIN" node add Sprite2D --name Clock --project "$WORK" >/dev/null
"$BIN" prop set Clock position 'Vector2(9, 9)' --project "$WORK" >/dev/null
"$BIN" scene save --project "$WORK" >/dev/null
grep -q 'name="Clock"' "$WORK/main.tscn" || fail "Clock was not saved"
"$BIN" editor history --project "$WORK" | sed 's/^/    /'

"$BIN" editor undo --count 2 --project "$WORK" | sed 's/^/    /'
"$BIN" scene save --project "$WORK" >/dev/null
grep -q 'name="Clock"' "$WORK/main.tscn" && fail "undo did not remove Clock from the saved scene"
"$BIN" editor status --project "$WORK" --quiet >/dev/null || true

"$BIN" editor redo --count 2 --project "$WORK" | sed 's/^/    /'
"$BIN" scene save --project "$WORK" >/dev/null
grep -q 'name="Clock"' "$WORK/main.tscn" || fail "redo did not restore Clock"
grep -q 'Vector2(9, 9)' "$WORK/main.tscn" || fail "redo did not restore the property value"

step "undo dry run"
"$BIN" editor undo --dry-run --project "$WORK" | sed 's/^/    /'
"$BIN" scene tree --project "$WORK" --quiet | grep -qx 'Clock' || fail "--dry-run undo mutated the scene"

step "M2: signals and groups"
"$BIN" node add Button --name Btn --project "$WORK" >/dev/null
"$BIN" signal connect Btn pressed Inst/Label set_text --project "$WORK" | sed 's/^/    /'
"$BIN" signal list Btn --connected-only --project "$WORK" | sed 's/^/    /'
"$BIN" group add Btn gameplay --project "$WORK" >/dev/null
GRP="$("$BIN" group list Btn --quiet --project "$WORK")"
[[ "$GRP" == *gameplay* ]] || fail "group add did not stick (got '$GRP')"
set +e
"$BIN" signal connect Btn no_such_signal Inst/Label set_text --project "$WORK" >/dev/null 2>&1
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "bad signal should exit 3, got $CODE"

step "M2: instance, resources"
"$BIN" node instance res://sub.tscn --name Sub2 --project "$WORK" | sed 's/^/    /'
"$BIN" res new Gradient res://new.tres --project "$WORK" | sed 's/^/    /'
"$BIN" res duplicate res://new.tres res://copy.tres --project "$WORK" | sed 's/^/    /'
"$BIN" res info res://copy.tres --project "$WORK" | sed 's/^/    /'

step "M2: project + script + fs"
"$BIN" project setting set application/config/description "gdcli fixture" --project "$WORK" >/dev/null
DESC="$("$BIN" project setting get application/config/description --quiet --project "$WORK")"
[[ "$DESC" == '"gdcli fixture"' || "$DESC" == "gdcli fixture" ]] || fail "setting roundtrip got $DESC"
"$BIN" project autoload add Boot res://boot.gd --project "$WORK" >/dev/null
"$BIN" project autoload list --project "$WORK" | sed 's/^/    /'
"$BIN" project autoload remove Boot --project "$WORK" >/dev/null
set +e
"$BIN" script check res://boot.gd res://nope.gd --project "$WORK" | sed 's/^/    /'
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "script check with a bad path should exit 3, got $CODE"
"$BIN" script open res://boot.gd --line 1 --project "$WORK" | sed 's/^/    /'
"$BIN" script files --project "$WORK" | sed 's/^/    /'
"$BIN" fs scan --wait --project "$WORK" | sed 's/^/    /'

step "M2: save and assert"
"$BIN" scene save --project "$WORK" >/dev/null
python3 - "$WORK" <<'PY'
import sys, pathlib
work = pathlib.Path(sys.argv[1])
text = (work / "main.tscn").read_text()
checks = {
    "connection": '[connection signal="pressed" from="Btn" to="Inst/Label" method="set_text"]',
    "group": 'groups=["gameplay"]',
    "Sub2 node": '[node name="Sub2" parent="."',
    "original instance kept": '[node name="Inst" parent="."',
}
missing = [k for k, v in checks.items() if v not in text]
if missing:
    raise SystemExit("missing from saved scene: %s" % missing)
if text.count("instance=ExtResource") < 2:
    raise SystemExit("Sub2 did not keep its instance reference:\n%s" % text)
for res in ("new.tres", "copy.tres"):
    if not (work / res).exists():
        raise SystemExit("missing resource file: %s" % res)
proj = (work / "project.godot").read_text()
if "gdcli fixture" not in proj:
    raise SystemExit("project.godot lost the setting:\n%s" % proj)
print("    M2 assertions ok:", ", ".join(checks), "+ resources + project settings")
PY

step "remaining M1 surface"
"$BIN" prop list Hero --changed --project "$WORK" --quiet | sed 's/^/    /'
"$BIN" prop set Hero position 'Vector2(5, 6)' --project "$WORK" >/dev/null
"$BIN" prop reset Hero position --project "$WORK" | sed 's/^/    /'
POS="$("$BIN" prop get Hero position --quiet --project "$WORK")"
[[ "$POS" == "Vector2(0, 0)" ]] || fail "prop.reset left position at $POS"
"$BIN" node rm Hero --project "$WORK" | sed 's/^/    /'
set +e
"$BIN" prop get Hero position --project "$WORK" >/dev/null 2>&1
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "removed node should answer NOT_FOUND (exit 3), got $CODE"

step "save-as + roots + reload"
"$BIN" scene save-as res://copies/main2.tscn --project "$WORK" | sed 's/^/    /'
[[ -f "$WORK/copies/main2.tscn" ]] || fail "save-as did not create copies/main2.tscn"
"$BIN" scene roots --project "$WORK" --quiet | sed 's/^/    /'
"$BIN" scene reload --project "$WORK" | sed 's/^/    /'
"$BIN" scene tree --project "$WORK" --quiet | sed 's/^/    /'
grep -q 'instance=ExtResource' "$WORK/copies/main2.tscn" || fail "save-as flattened the instance"

step "M5: plugin toggles"
PLUGINS="$("$BIN" project plugins list --project "$WORK" --json)"
python3 - "$PLUGINS" <<'PY'
import json, sys
plugins = {p["name"]: p for p in json.loads(sys.argv[1])["plugins"]}
assert "gdcli" in plugins and plugins["gdcli"]["enabled"], plugins
assert "probe" in plugins and not plugins["probe"]["enabled"], plugins
print("    listed:", sorted(plugins))
PY
"$BIN" project plugins enable probe --project "$WORK" | sed 's/^/    /'
"$BIN" project plugins list --project "$WORK" --quiet | tr '\n' ' ' | sed 's/^/    /'; echo
set +e
"$BIN" project plugins enable nope --project "$WORK" >/dev/null 2>&1
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "enabling an unknown plugin should exit 3, got $CODE"
"$BIN" project plugins disable probe --project "$WORK" | sed 's/^/    /'

step "M5: private install"
PW="$WORK/private"
rm -rf "$PW"; mkdir -p "$PW"
cp "$REPO"/tests/fixture/project.godot "$PW"/
"$BIN" plugin install --check --private --project "$PW" >/dev/null
[[ ! -f "$PW/.gitignore" ]] || fail "--check wrote .gitignore"
"$BIN" plugin install --private --project "$PW" | sed 's/^/    /'
grep -qx 'addons/gdcli/' "$PW/.gitignore" || fail ".gitignore missing addons/gdcli/"
"$BIN" plugin install --private --project "$PW" >/dev/null
[[ "$(grep -c '^addons/gdcli/$' "$PW/.gitignore")" == "1" ]] || fail ".gitignore entry duplicated"

step "M6: input map"
"$BIN" project input add-action jump --deadzone 0.2 --project "$WORK" | sed 's/^/    /'
"$BIN" project input add-event jump --key Space --modifiers shift --project "$WORK" | sed 's/^/    /'
"$BIN" project input add-event jump --joy-button 0 --project "$WORK" | sed 's/^/    /'
"$BIN" project input list --action jump --project "$WORK" | sed 's/^/    /'
grep -q '"device":-1' "$WORK/project.godot" || fail "input events are not written with device -1"
grep -q '"keycode":32' "$WORK/project.godot" || fail "Space was not serialized as keycode 32"
grep -q '"shift_pressed":true' "$WORK/project.godot" || fail "the shift modifier was dropped"

set +e
"$BIN" project input add-event jump --key Space --modifiers shift --project "$WORK" >/dev/null 2>&1
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "duplicate binding should exit 3, got $CODE"

"$BIN" project input remove-event jump --index 1 --project "$WORK" | sed 's/^/    /'
"$BIN" project input rename-action jump leap --project "$WORK" | sed 's/^/    /'
"$BIN" project input list --project "$WORK" | sed 's/^/    /'
"$BIN" project input remove-action leap --project "$WORK" | sed 's/^/    /'
grep -q '^leap=' "$WORK/project.godot" && fail "remove-action left leap in project.godot"
python3 - "$WORK/project.godot" <<'PY'
import sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text()
assert 'jump=' not in text and 'leap=' not in text, "an input action survived remove-action"
print("    input map cleaned up")
PY

step "M8: command palette"
"$BIN" editor palette list --project "$WORK" | sed 's/^/    /'
PALETTE="$("$BIN" editor palette list --project "$WORK" --json)"
python3 - "$PALETTE" <<'PY'
import json, sys
entries = json.loads(sys.argv[1])["entries"]
assert len(entries) == 3, entries
assert all(e.startswith("gdcli: ") for e in entries), entries
print("    entries:", ", ".join(entries))
PY
"$BIN" editor palette run "gdcli: Show bridge status" --project "$WORK" | sed 's/^/    /'
set +e
"$BIN" editor palette run "gdcli: nope" --project "$WORK" >/dev/null 2>&1
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "running an unknown palette entry should exit 3, got $CODE"

step "M3: ui state, play/stop, game read-only"
"$BIN" editor select Inst --project "$WORK" | sed 's/^/    /'
"$BIN" editor select Inst Btn --add --project "$WORK" | sed 's/^/    /'
"$BIN" editor inspect Inst --project "$WORK" | sed 's/^/    /'
"$BIN" editor main-screen 3d --project "$WORK" | sed 's/^/    /'
"$BIN" editor toast "gdcli e2e" --project "$WORK" | sed 's/^/    /'
"$BIN" editor status --project "$WORK" | sed 's/^/    /'
"$BIN" editor play --wait --project "$WORK" | sed 's/^/    /'
PLAYING="$("$BIN" editor status --project "$WORK" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["playing"])')"
[[ "$PLAYING" == "True" || "$PLAYING" == "true" ]] || fail "play --wait left playing=$PLAYING"
"$BIN" game status --project "$WORK" | sed 's/^/    /'
LOGS_OUT="$("$BIN" game logs --limit 5 --project "$WORK")"
[[ -n "$LOGS_OUT" ]] || fail "game logs printed nothing when the buffer is empty"
echo "$LOGS_OUT" | sed 's/^/    /'
"$BIN" editor stop --project "$WORK" | sed 's/^/    /'

set +e
"$BIN" editor screenshot --out "$WORK/should-not-exist.png" --viewport 2d --project "$WORK" >/dev/null 2>"$WORK/shot-err.txt"
CODE=$?
set -e
[[ $CODE -eq 3 ]] || fail "screenshot on a dummy renderer should exit 3, got $CODE"
[[ ! -f "$WORK/should-not-exist.png" ]] || fail "screenshot wrote a file on a dummy renderer"
grep -qi "display\|xvfb\|headless" "$WORK/shot-err.txt" || fail "screenshot error has no display hint: $(cat "$WORK/shot-err.txt")"

if [[ "${E2E_GUI:-0}" == "1" ]]; then
	step "M3 GUI (xvfb): screenshots, play, game logs"
	GW="$WORK/gui"
	rm -rf "$GW"; mkdir -p "$GW"
	cp "$REPO"/tests/fixture/project.godot "$REPO"/tests/fixture/*.tscn "$REPO"/tests/fixture/*.gd "$GW"/
	"$BIN" plugin install --project "$GW" >/dev/null
	# Force X11: with WAYLAND_DISPLAY inherited the editor runs on the real session and the
	# game it spawns (--display-driver wayland --wid ...) never initialises its scene tree.
	env -u WAYLAND_DISPLAY xvfb-run -a -s "-screen 0 1600x1000x24" \
		"$GODOT" --editor --display-driver x11 --path "$GW" res://main.tscn >"$GW/editor.log" 2>&1 &
	GUI_PID=$!
	trap 'kill "$EDITOR_PID" "$GUI_PID" 2>/dev/null || true; pkill -f "$GW" 2>/dev/null || true' EXIT
	for _ in $(seq 1 120); do
		[[ -f "$GW/.godot/gdcli/endpoint.json" ]] && break
		sleep 0.5
	done
	[[ -f "$GW/.godot/gdcli/endpoint.json" ]] || { tail -20 "$GW/editor.log"; fail "xvfb editor never came up"; }

	"$BIN" editor screenshot --out "$GW/shot2d.png" --viewport 2d --project "$GW" | sed 's/^/    /'
	"$BIN" editor screenshot --out "$GW/shot3d.png" --viewport 3d --project "$GW" | sed 's/^/    /'
	"$BIN" editor screenshot --out "$GW/whole.png" --viewport whole --project "$GW" | sed 's/^/    /'
	python3 - "$GW" <<'PY'
import struct, sys, pathlib
for name in ("shot2d.png", "shot3d.png", "whole.png"):
    data = pathlib.Path(sys.argv[1], name).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", name
    w, h = struct.unpack(">II", data[16:24])
    assert w > 100 and h > 100, (name, w, h)
    print("    %s %dx%d ok" % (name, w, h))
PY
	step "M8 GUI: palette screenshot"
	"$BIN" editor palette run "gdcli: Screenshot 2D view" --project "$GW" | sed 's/^/    /'
	sleep 2
	SHOT="$(ls -1t "$GW"/.godot/gdcli/screenshots/shot2d-*.png 2>/dev/null | head -1)"
	[[ -n "$SHOT" ]] || fail "palette screenshot produced no file"
	python3 - "$SHOT" <<'PY'
import struct, sys, pathlib
data = pathlib.Path(sys.argv[1]).read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
w, h = struct.unpack(">II", data[16:24])
assert w > 100 and h > 100, (w, h)
print("    palette shot %dx%d ok" % (w, h))
PY

	step "M4 GUI: runtime bridge"
	"$BIN" runtime install --project "$GW" | sed 's/^/    /'
	"$BIN" runtime install --project "$GW" | sed 's/^/    /'
	"$BIN" editor play --wait --project "$GW" | sed 's/^/    /'
	sleep 4
	"$BIN" game ping --project "$GW" | sed 's/^/    /'
	RT_V="$("$BIN" game ping --project "$GW" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["runtime"])')"
	[[ "$RT_V" == "$CLI_V" ]] || fail "runtime $RT_V != cli $CLI_V"
	echo "    cli == runtime: $RT_V"
	"$BIN" game tree --depth 2 --project "$GW" | sed 's/^/    /'
	"$BIN" game get Inst/Label text --project "$GW" | sed 's/^/    /'
	"$BIN" game set Inst/Label text '"patched"' --project "$GW" | sed 's/^/    /'
	GOT="$("$BIN" game get Inst/Label text --quiet --project "$GW")"
	[[ "$GOT" == *patched* ]] || fail "game set did not take effect in the running game (got '$GOT')"
	EVAL="$("$BIN" game eval '1 + 1' --quiet --project "$GW")"
	[[ "$EVAL" == "2" ]] || fail "game eval returned '$EVAL'"
	LOGS_JSON="$("$BIN" game logs --limit 50 --project "$GW" --json)"
	python3 - "$LOGS_JSON" <<'PY'
import json, sys
lines = json.loads(sys.argv[1])["lines"]
pairs = {(l["kind"], l["text"].strip()) for l in lines}
assert any(k == "output" and "fixture: main scene ready" in t for k, t in pairs), pairs
assert any(k == "error" and "fixture: stderr line" in t for k, t in pairs), pairs
print("    captured %d log lines, print + stderr both present" % len(lines))
PY
	ERR_ONLY="$("$BIN" game logs --kind error --limit 50 --project "$GW" --json)"
	python3 - "$ERR_ONLY" <<'PY'
import json, sys
lines = json.loads(sys.argv[1])["lines"]
assert lines, "kind=error returned nothing"
assert all(l["kind"] == "error" for l in lines), lines
print("    kind filter ok: %d error line(s)" % len(lines))
PY

	"$BIN" game screenshot --out "$GW/game.png" --project "$GW" | sed 's/^/    /'
	python3 - "$GW/game.png" <<'PY'
import struct, sys, pathlib
data = pathlib.Path(sys.argv[1]).read_bytes()
assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
w, h = struct.unpack(">II", data[16:24])
assert w > 100 and h > 100, (w, h)
print("    game.png %dx%d ok" % (w, h))
PY
	"$BIN" game logs --limit 10 --project "$GW" | sed 's/^/    /'
	"$BIN" editor stop --project "$GW" | sed 's/^/    /'

	set +e
	"$BIN" game ping --project "$GW" >/dev/null 2>&1
	CODE=$?
	set -e
	[[ $CODE -eq 3 ]] || fail "game ping with no game should exit 3, got $CODE"
	"$BIN" runtime uninstall --project "$GW" | sed 's/^/    /'
fi

echo
echo "PASS"
