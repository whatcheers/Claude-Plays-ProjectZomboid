"""Drive ClaudeBot (Project Zomboid mod) turn by turn.

  python pz.py state                 print the last state
  python pz.py do "go 100 200" ...   send a turn, wait for the game to pause, print state
  python pz.py reload                hot-reload bot.lua in the game
  python pz.py raw                   dump state.json
"""
import json, os, sys, time

D = os.path.expanduser("~/Zomboid/Lua/claudebot")
STATE, CMD = os.path.join(D, "state.json"), os.path.join(D, "cmd.txt")


def read_state():
    for _ in range(20):
        try:
            with open(STATE, encoding="utf-8", errors="replace") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.1)
    return None


def fmt_item(i, indent="  "):
    bits = [f"#{i['id']} {i['name']}"]
    for k in ("hand", "worn", "rotten", "cooked", "frozen", "rawDanger", "poison", "book"):
        if i.get(k):
            bits.append(k if i[k] is True else f"{k}={i[k]}")
    if "hunger" in i:
        bits.append(f"hunger {i['hunger']}")
    if "fluid" in i:
        bits.append(f"fluid {i['fluid']} {i.get('fluidType') or ''}".strip())
    if i.get("weapon"):
        bits.append(f"dmg {i['dmg']} rng {i['range']} cond {i['cond']}")
    bits.append(f"{i.get('w', 0)}kg")
    out = [indent + " | ".join(str(b) for b in bits)]
    for sub in i.get("items") or []:
        out += fmt_item(sub, indent + "    ")
    return out


def show(s):
    if not s:
        print("no state")
        return
    if s.get("running"):
        print(f"turn {s['turn']} still running")
        return
    L = []
    t = s.get("time", {})
    L.append(f"== turn {s.get('turn')} | pause reason: {s.get('reason')} | {t.get('month')}/{t.get('day')} "
             f"{t.get('hour', 0):02d}:{t.get('min', 0):02d} (day {t.get('daysSurvived')})")
    if s.get("error"):
        L.append("STATE ERROR: " + s["error"])
    if s.get("loaderErr"):
        L.append("LOADER ERR: " + s["loaderErr"])
    for r in s.get("results") or []:
        L.append(f"  {'ok ' if r.get('ok') else 'ERR'} {r.get('cmd')}: {r.get('msg')}")
    if s.get("dead"):
        L.append("*** DEAD ***")
    pos = s.get("pos")
    if pos:
        st = s.get("stats", {})
        L.append(f"pos {pos['x']},{pos['y']},{pos['z']} {'outside' if s.get('outside') else 'inside ' + str(s.get('room'))} | "
                 f"health {s.get('health')} | weight {s.get('weight')} | hand: {s.get('primary')}")
        L.append("stats " + " ".join(f"{k}={v}" for k, v in st.items() if v))
        for w in s.get("wounds") or []:
            L.append(f"  wound {w['part']} hp {w['hp']} {w['flags']}")
        if s.get("queue"):
            L.append("queue: " + " > ".join(s["queue"]))
    zs = s.get("zombies") or []
    if zs:
        L.append(f"zombies ({len(zs)}):")
        for z in zs[:15]:
            flags = " ".join(k for k in ("seen", "down", "crawler", "targetingMe") if z.get(k))
            L.append(f"  Z#{z['id']} at {z['x']},{z['y']} d={z['d']} {flags}")
    m = s.get("map")
    if m:
        x0, y0, lines = m["x0"], m["y0"], m["lines"]
        n = (len(lines) - 1) // 2
        L.append(f"map: tiles x {x0}..{x0 + n - 1} (every 5th labelled), y {y0}..{y0 + n - 1}")
        cols = [" "] * len(lines[0])
        for tx in range(n):
            x = x0 + tx
            if x % 5 == 0:
                lab = str(x % 1000)
                for k, ch in enumerate(lab):
                    c = 2 * tx + 1 + k
                    if c < len(cols):
                        cols[c] = ch
        L.append("      " + "".join(cols))
        for r, line in enumerate(lines):
            lab = str(y0 + (r - 1) // 2) if r % 2 == 1 else ""
            L.append(lab.rjust(5) + " " + line)
    if s.get("doors"):
        L.append("doors: " + "; ".join(f"{d['x']},{d['y']}{d['edge']}{' open' if d.get('open') else ''}{' LOCKED' if d.get('locked') else ''}{' barr' if d.get('barricaded') else ''}" for d in s["doors"]))
    if s.get("windows"):
        L.append("windows: " + "; ".join(f"{w['x']},{w['y']}{w['edge']}{' open' if w.get('open') else ''}{' smashed' if w.get('smashed') else ''}{' noglass' if w.get('glassRemoved') else ''}{' barr' if w.get('barricaded') else ''}{' locked' if w.get('locked') else ''}" for w in s["windows"]))
    if s.get("water"):
        L.append("water: " + "; ".join(f"{w['x']},{w['y']} {w['name']} {w['amount']}{' TAINTED' if w.get('tainted') else ''}" for w in s["water"]))
    cs = s.get("containers") or []
    if cs:
        L.append("containers:")
        for c in cs:
            if c.get("items") is not None:
                L.append(f"  [{c['x']},{c['y']} #{c['i']} {c['kind']}] {c['n']} items")
                for i in c["items"]:
                    L += fmt_item(i, "      ")
        far = [c for c in cs if c.get("items") is None]
        if far:
            L.append("  farther: " + "; ".join(f"{c['x']},{c['y']} {c['kind']}({c['n']})" for c in far))
    fl = s.get("floor") or []
    if fl:
        L.append("floor items: " + "; ".join(f"{f['x']},{f['y']} {f.get('name')}{' #' + str(f['id']) if 'id' in f else ''}" for f in fl))
    inv = s.get("inventory") or []
    if inv:
        L.append("inventory:")
        for i in inv:
            L += fmt_item(i)
    print("\n".join(L))


def do(cmds, timeout=180):
    tid = int(time.time() * 10) % 10**9
    with open(CMD, "w", encoding="utf-8") as f:
        f.write(str(tid) + "\n" + "\n".join(cmds) + "\n")
    t0 = time.time()
    while time.time() - t0 < timeout:
        time.sleep(0.4)
        s = read_state()
        if s and s.get("turn") == tid and not s.get("running"):
            show(s)
            return
    print(f"timeout after {timeout}s waiting for turn {tid}")
    show(read_state())


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    a = sys.argv[1:]
    if not a or a[0] == "state":
        show(read_state())
    elif a[0] == "raw":
        print(json.dumps(read_state(), indent=1))
    elif a[0] == "reload":
        with open(os.path.join(D, "reload.txt"), "w") as f:
            f.write(str(time.time()))
        time.sleep(2)
        print(open(os.path.join(D, "loader.txt")).read() if os.path.exists(os.path.join(D, "loader.txt")) else "no loader.txt")
    elif a[0] == "do":
        do(a[1:])
    else:
        print(__doc__)
