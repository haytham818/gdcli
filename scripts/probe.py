#!/usr/bin/env python3
"""Minimal gdcli development client (NDJSON over loopback).

Usage:
  scripts/probe.py --project /tmp/gdcli-plugin-test            # run the E2E scenario
  scripts/probe.py --project /tmp/gdcli-plugin-test --cmd scene.tree --args '{"props":true}'

The endpoint lives at <project>/.godot/gdcli/endpoint.json and is written by the
editor plugin. Only loopback is used.
"""

import argparse
import json
import os
import socket
import sys
import time

ENDPOINT = os.path.join(".godot", "gdcli", "endpoint.json")


class Client:
    def __init__(self, endpoint_path):
        with open(endpoint_path, "r", encoding="utf-8") as fh:
            self.endpoint = json.load(fh)
        self.sock = socket.create_connection(
            ("127.0.0.1", self.endpoint["port"]), timeout=15
        )
        self.stream = self.sock.makefile("rwb")
        self.next_id = 1
        hello = self._roundtrip({"token": self.endpoint["token"], "protocol": 1})
        if not hello.get("ok"):
            raise RuntimeError(f"handshake failed: {hello}")
        self.hello = hello["data"]

    def _readline(self):
        line = self.stream.readline()
        if not line:
            raise ConnectionError("editor closed the connection")
        return json.loads(line)

    def _write(self, obj):
        self.stream.write((json.dumps(obj) + "\n").encode("utf-8"))
        self.stream.flush()

    def _roundtrip(self, obj):
        self._write(obj)
        reply = self._readline()
        print("<<< " + json.dumps(reply, ensure_ascii=False))
        return reply

    def call(self, cmd, args=None, **opts):
        request_id = str(self.next_id)
        self.next_id += 1
        request = {"id": request_id, "cmd": cmd, "args": args or {}}
        if opts:
            request["opts"] = opts
        print(">>> " + json.dumps(request, ensure_ascii=False))
        reply = self._roundtrip(request)
        if reply.get("id") != request_id:
            raise AssertionError(f"id mismatch: {reply}")
        return reply

    def close(self):
        self.stream.close()
        self.sock.close()


def wait_for_endpoint(project, timeout=60.0):
    path = os.path.join(project, ENDPOINT)
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path):
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    json.load(fh)
                return path
            except (OSError, ValueError):
                pass
        time.sleep(0.1)
    raise TimeoutError(f"no endpoint at {path}")


def scenario(client):
    opened = client.call("scene.open", {"path": "res://main.tscn"})
    assert opened["ok"], opened
    assert opened["data"]["path"] == "res://main.tscn", opened

    tree = client.call("scene.tree", {"props": True})
    assert tree["ok"], tree
    nodes = {node["path"]: node for node in tree["data"]["nodes"]}
    inst = nodes.get("Inst")
    assert inst, f"no Inst in {sorted(nodes)}"
    assert inst["instance"] == "res://sub.tscn", inst
    assert "position" in inst["props"], inst

    hero = client.call("node.add", {"type": "Sprite2D", "name": "Hero", "parent": ""})
    assert hero["ok"], hero
    assert hero["data"]["path"] == "Hero", hero

    moved = client.call("prop.set", {
        "target": "Hero", "name": "position", "value": "Vector2(3, 4)", "as": "gd",
    })
    assert moved["ok"], moved
    assert moved["data"]["value_text"] == "Vector2(3, 4)", moved

    dup = client.call("node.dup", {"path": "Hero", "name": "Hero2"})
    assert dup["ok"], dup
    assert dup["data"]["path"] == "Hero2", dup

    renamed = client.call("node.rename", {"path": "Hero2", "name": "Villain"})
    assert renamed["ok"], renamed
    assert renamed["data"]["path"] == "Villain", renamed

    reparented = client.call("node.mv", {"path": "Villain", "to": "Inst"})
    assert reparented["ok"], reparented
    assert reparented["data"]["path"] == "Inst/Villain", reparented

    bad = client.call("prop.set", {"target": "Hero", "name": "nope", "value": "1"})
    assert not bad["ok"] and bad["error"]["code"] in ("BAD_ARGS", "NOT_FOUND"), bad

    unknown = client.call("does.not.exist")
    assert not unknown["ok"] and unknown["error"]["code"] == "UNKNOWN_CMD", unknown

    saved = client.call("scene.save")
    assert saved["ok"], saved
    print(f"scenario ok: {saved['data']}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True, help="Godot project directory")
    parser.add_argument("--cmd", help="single command to run instead of the scenario")
    parser.add_argument("--args", default="{}", help="JSON args for --cmd")
    parser.add_argument("--timeout", type=float, default=60.0)
    options = parser.parse_args()

    endpoint = wait_for_endpoint(options.project, options.timeout)
    client = Client(endpoint)
    print(json.dumps({"handshake": client.hello}, ensure_ascii=False))
    try:
        if options.cmd:
            reply = client.call(options.cmd, json.loads(options.args))
            print(json.dumps(reply, indent=2, ensure_ascii=False))
            return 0 if reply.get("ok") else 3
        scenario(client)
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())
