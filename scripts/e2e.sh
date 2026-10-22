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
cp "$REPO"/tests/fixture/project.godot "$REPO"/tests/fixture/*.tscn "$WORK"/

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

echo
echo "PASS"
