"""python tests/test_turnlog.py: pz.py do's turn log line (no game needed)."""
import json, os, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pz

s = {"turn": 7, "reason": "done", "time": {"month": 7, "day": 10, "hour": 16, "min": 5, "daysSurvived": 1.4},
     "results": [{"cmd": "go 1 2", "ok": False, "msg": "PATH FAILED (no route)"},
                 {"cmd": "look", "ok": False, "msg": "NOT RUN: the queue was dropped after 'go 1 2'"}],
     "pos": {"x": 1, "y": 2, "z": 0}, "health": 90, "stats": {"hunger": 0.3}, "inventory": [], "reflexes": ["equipped Axe"]}
path = os.path.join(tempfile.mkdtemp(), "turns.jsonl")
pz.log_turn(["go 1 2", "look"], s, path)
pz.log_turn(["look"], None, path)
recs = [json.loads(l) for l in open(path, encoding="utf-8")]
assert len(recs) == 2
r = recs[0]
assert r["cmds"] == ["go 1 2", "look"] and r["turn"] == 7 and r["reason"] == "done"
assert r["results"][0] == {"cmd": "go 1 2", "ok": False, "msg": "PATH FAILED (no route)"}
assert r["reflexes"] == ["equipped Axe"] and any("health 90" in b for b in r["brief"])
assert recs[1]["reason"].startswith("timeout") and recs[1]["cmds"] == ["look"]
print("PASS: turn log lines")

# agent tag: PZ_AGENT names who sent the turn; unset means the supervisor
os.environ["PZ_AGENT"] = "fire-run"
pz.log_turn(["look"], s, path)
del os.environ["PZ_AGENT"]
pz.log_turn(["look"], s, path)
recs = [json.loads(l) for l in open(path, encoding="utf-8")]
assert recs[2]["agent"] == "fire-run" and recs[3]["agent"] == "supervisor", recs[2:]

# reports: saved per agent, newest wins, served as {name: {t, text}}
rdir = os.path.join(tempfile.mkdtemp(), "reports")
pz.save_report("fire-run", "STOPPED: goals done\nTURNS: 13", rdir)
pz.save_report("fire-run", "STOPPED: second\nTURNS: 2", rdir)
reps = pz.load_reports(rdir)
assert list(reps) == ["fire-run"] and reps["fire-run"]["text"].startswith("STOPPED: second"), reps
print("PASS: agent tags and reports")
