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

step "plugin install"
"$BIN" plugin install --project "$WORK" | sed 's/^/    /'
grep -q 'res://addons/gdcli/plugin.cfg' "$WORK/project.godot" || fail "project.godot not patched"

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
"$BIN" game logs --limit 5 --project "$WORK" | sed 's/^/    /'
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
	xvfb-run -a -s "-screen 0 1600x1000x24" "$GODOT" --editor --path "$GW" res://main.tscn >"$GW/editor.log" 2>&1 &
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
	"$BIN" editor play --wait --project "$GW" | sed 's/^/    /'
	sleep 4
	"$BIN" game logs --limit 10 --project "$GW" | sed 's/^/    /'
	"$BIN" editor stop --project "$GW" | sed 's/^/    /'
fi

echo
echo "PASS"
