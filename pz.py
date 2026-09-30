"""Drive ClaudeBot (Project Zomboid B42 mod) turn by turn. See PLAYING.md.

  python pz.py do "go 100 200" ...   send a turn, wait for the game to pause, print a short summary
                                     (add --full to print everything)
  python pz.py state                 re-print the last summary
  python pz.py full                  the whole last state (map, nearby, inventory)
  python pz.py map | near | inv      just one section of the last state (inv all: every id)
  python pz.py raw                   dump state.json
  python pz.py reload                hot-reload ClaudeBot.lua in the running game
  python pz.py eval "R = p:getX()"   run Lua in the game (p = player, R = result)

Set ZOMBOID_DIR if your Zomboid user folder isn't ~/Zomboid.
"""
import json, os, sys, time

VERSION = "0.2.0"  # keep in step with mod.info and B.VERSION in ClaudeBot.lua

D = os.path.join(os.environ.get("ZOMBOID_DIR") or os.path.expanduser("~/Zomboid"), "Lua", "claudebot")
STATE, CMD = os.path.join(D, "state.json"), os.path.join(D, "cmd.txt")


def read_state():
    for _ in range(20):
        try:
            with open(STATE, encoding="utf-8", errors="replace") as f:
                return json.load(f)
        except (OSError, ValueError):
            time.sleep(0.1)
    return None


def fmt_item(i, indent="  ", group=True, n=1, ids=None):
    bits = [f"#{i['id']} {i['name']}" + (f" x{n} (ids #{ids[0]}..#{ids[-1]}; inv all lists them)" if n > 1 else "")]
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
    out += fmt_items(i.get("items") or [], indent + "    ", group)
    return out


def fmt_items(items, indent="  ", group=True):
    """One line per item; with group, identical plain items (no bag contents) share a line."""
    if not group:
        return [line for i in items for line in fmt_item(i, indent, False)]
    key = lambda i: json.dumps({k: v for k, v in i.items() if k != "id"}, sort_keys=True)
    out, seen = [], {}
    for i in items:
        if i.get("items"):
            out.append((i, [i["id"]]))
            continue
        k = key(i)
        if k in seen:
            seen[k][1].append(i["id"])
        else:
            seen[k] = (i, [i["id"]])
            out.append(seen[k])
    return [line for i, ids in out for line in fmt_item(i, indent, True, len(ids), ids)]


def group_names(pairs):
    """[(name, id)] -> ["Nails x96", "Plank #123"]"""
    counts, first = {}, {}
    for n, i in pairs:
        counts[n] = counts.get(n, 0) + 1
        first.setdefault(n, i)
    return [f"{n} x{c}" if c > 1 else f"{n} #{first[n]}" for n, c in counts.items()]


def sec_head(s):
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
    return L


def sec_body(s, all_wounds=False):
    L = []
    pos = s.get("pos")
    if pos:
        st = s.get("stats", {})
        L.append(f"pos {pos['x']},{pos['y']},{pos['z']} {'outside' if s.get('outside') else 'inside ' + str(s.get('room'))} | "
                 f"health {s.get('health')} | weight {s.get('weight')}{' OVERLOADED' if s.get('overloaded') else ''} | hand: {s.get('primary')}")
        if s.get("fort"):
            L.append("fort: " + s["fort"])
        L.append("stats " + " ".join(f"{k}={v}" for k, v in st.items() if v))
        for w in s.get("wounds") or []:
            if all_wounds or w["flags"] or w["hp"] < 90:
                L.append(f"  wound {w['part']} hp {w['hp']} {w['flags']}")
        if s.get("queue"):
            L.append("queue: " + " > ".join(s["queue"]))
    zs = s.get("zombies") or []
    if zs:
        zs = sorted(zs, key=lambda z: (not z.get("targetingMe"), z["d"]))
        L.append(f"zombies ({len(zs)}):")
        for z in zs[:15]:
            flags = " ".join(k for k in ("seen", "down", "crawler", "targetingMe") if z.get(k))
            L.append(f"  Z#{z['id']} at {z['x']},{z['y']} d={z['d']} {flags}")
    if s.get("task"):
        L.append("task: " + s["task"])
    if s.get("reflexes"):
        L.append("reflexes: " + "; ".join(s["reflexes"]))
    if s.get("scan"):
        L.append("buildings:")
        L += ["  " + b for b in s["scan"]]
    if s.get("survey"):
        L.append("survey (x,y,z container: items):")
        L += ["  " + b for b in s["survey"]]
    return L


def sec_map(s):
    L = []
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
    return L


def sec_near(s):
    L = []
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
    return L


def sec_inv(s, group=True):
    L = []
    inv = s.get("inventory") or []
    if inv:
        L.append("inventory:")
        L += fmt_items(inv, "  ", group)
    return L


def flat_items(items):
    out = {}
    for i in items or []:
        out[i["id"]] = i["name"]
        out.update(flat_items(i.get("items")))
    return out


def sec_summary(s, prev):
    """A line or two standing in for the map/near/inv sections, plus inventory changes."""
    L = []
    if prev is not None:
        now, before = flat_items(s.get("inventory")), flat_items(prev)
        gained = ["+" + g for g in group_names([(n, i) for i, n in now.items() if i not in before])]
        lost = ["-" + g for g in group_names([(n, i) for i, n in before.items() if i not in now])]
        if gained or lost:
            L.append("inventory changed: " + ", ".join(gained + lost))
    cs = s.get("containers") or []
    reach = [c for c in cs if c.get("items") is not None]
    bits = []
    if reach:
        bits.append("in reach: " + ", ".join(f"{c['kind']}@{c['x']},{c['y']}({c['n']})" for c in reach))
    if len(cs) > len(reach):
        bits.append(f"{len(cs) - len(reach)} more containers")
    ds = s.get("doors") or []
    if ds:
        bits.append(f"{len(ds)} doors ({sum(1 for d in ds if d.get('open'))} open)")
    ws = s.get("windows") or []
    if ws:
        bad = sum(1 for w in ws if w.get("open") or w.get("smashed"))
        bits.append(f"{len(ws)} windows" + (f" ({bad} open/smashed)" if bad else ""))
    if s.get("water"):
        bits.append("water here")
    if s.get("floor"):
        bits.append(f"{len(s['floor'])} floor items")
    if bits:
        L.append("near: " + "; ".join(bits))
    L.append("(pz.py near | map | inv | full for detail)")
    return L


def show(s, mode="summary", prev=None):
    if not s:
        print("no state")
        return
    if s.get("running"):
        print(f"turn {s['turn']} still running")
        return
    if mode == "summary":
        L = sec_head(s) + sec_body(s) + sec_summary(s, prev)
    elif mode == "full":
        b = s.get("base")
        orders = [f"policy: {s.get('policy')}", "base: " + (f"{b['x']},{b['y']},{b['z']}" if b else "none")]
        L = sec_head(s) + sec_body(s, all_wounds=True) + [" | ".join(orders)] + sec_map(s) + sec_near(s) + sec_inv(s)
    else:
        L = {"map": sec_map, "near": sec_near, "inv": sec_inv}[mode](s)
    print("\n".join(L))


PREV = os.path.join(D, "prev_inventory.json")


def load_prev():
    try:
        with open(PREV, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


# ---- driving: the mod writes the keys to hold to keys.txt; we press them in the game window.
# Lua can't: the car reads GameKeyboard, which has no setter.
KEYS = os.path.join(D, "keys.txt")
SCAN = {"W": 0x11, "A": 0x1E, "S": 0x1F, "D": 0x20, "SPACE": 0x39}


class KeyPump:
    def __init__(self):
        self.held, self.seq, self.mtime, self.hwnd = set(), None, 0, None
        self.grabbed = self.yielded = False
        if os.name != "nt":
            self.ok = False
            return
        import ctypes
        from ctypes import wintypes
        self.ok, self.ct, self.u32 = True, ctypes, ctypes.windll.user32

        class KEYBDINPUT(ctypes.Structure):
            _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]

        class INPUT(ctypes.Structure):
            class _U(ctypes.Union):
                _fields_ = [("ki", KEYBDINPUT), ("pad", ctypes.c_byte * 32)]
            _anonymous_ = ("u",)
            _fields_ = [("type", wintypes.DWORD), ("u", _U)]
        self.KEYBDINPUT, self.INPUT = KEYBDINPUT, INPUT

    def _send(self, scan, up):
        i = self.INPUT(type=1)
        i.ki = self.KEYBDINPUT(0, scan, 0x0008 | (0x0002 if up else 0), 0, 0)
        self.u32.SendInput(1, self.ct.byref(i), self.ct.sizeof(i))

    def _window(self):
        if self.hwnd and self.u32.IsWindow(self.hwnd):
            return self.hwnd
        found = []
        buf = self.ct.create_unicode_buffer(256)

        @self.ct.WINFUNCTYPE(self.ct.c_bool, self.ct.c_void_p, self.ct.c_void_p)
        def cb(h, _):
            self.u32.GetWindowTextW(h, buf, 256)
            if buf.value.startswith("Project Zomboid") and self.u32.IsWindowVisible(h):
                found.append(h)
            return True
        self.u32.EnumWindows(cb, 0)
        self.hwnd = found[0] if found else None
        return self.hwnd

    def _focus(self):
        h = self._window()
        if h and self.u32.GetForegroundWindow() != h:
            self._send(0x38, False); self._send(0x38, True)  # an Alt tap lets SetForegroundWindow through
            self.u32.SetForegroundWindow(h)
            time.sleep(0.05)
        return h and self.u32.GetForegroundWindow() == h

    def set(self, want):
        # take the window once per turn; if the user clicks away after that, let go of every
        # key and leave them the window (grabbing it back fights them when they step in)
        if want and not self.yielded:
            h = self._window()
            if not self.grabbed:
                self.grabbed = True
                self._focus()
            if not h or self.u32.GetForegroundWindow() != h:
                self.yielded = True
                print("driving: the game window lost focus; keys released until the next turn")
        if self.yielded:
            want = set()
        for k in self.held - want:
            self._send(SCAN[k], True)
        for k in want - self.held:
            self._send(SCAN[k], False)
        self.held = want

    def poll(self):
        if not self.ok:
            return
        try:
            m = os.path.getmtime(KEYS)
        except OSError:
            return
        if m != self.mtime:
            self.mtime = m
            try:
                lines = open(KEYS, encoding="utf-8").read().splitlines()
            except OSError:
                return
            self.want = {k for k in (lines[1].split() if len(lines) > 1 else []) if k in SCAN}
        if getattr(self, "want", None) is not None:
            self.set(self.want)

    def release(self):
        if self.ok and self.held:
            self.set(set())


def do(cmds, timeout=600, full=False):
    os.makedirs(D, exist_ok=True)
    tid = int(time.time() * 10) % 10**9
    with open(CMD, "w", encoding="utf-8") as f:
        f.write(str(tid) + "\n" + "\n".join(cmds) + "\n")
    t0, pump, last = time.time(), KeyPump(), 0
    try:
        while time.time() - t0 < timeout:
            time.sleep(0.03)
            pump.poll()
            if time.time() - last < 0.4:
                continue
            last = time.time()
            s = read_state()
            if s and s.get("turn") == tid and not s.get("running"):
                pump.release()
                if str(s.get("version")) != VERSION:
                    print(f"WARNING: the game is running ClaudeBot {s.get('version')}, this driver is {VERSION}. Run `pz.py reload`.")
                show(s, "full" if full else "summary", load_prev())
                if s.get("inventory") is not None:
                    with open(PREV, "w", encoding="utf-8") as f:
                        json.dump(s["inventory"], f)
                return
    finally:
        pump.release()
    print(f"timeout after {timeout}s waiting for turn {tid}. Is the game running, with ClaudeBot enabled and a character in the world?")
    show(read_state())


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    a = sys.argv[1:]
    if not a or a[0] == "state":
        show(read_state())
    elif a[0] == "inv" and a[1:2] == ["all"]:
        print("\n".join(sec_inv(read_state(), group=False)))
    elif a[0] in ("full", "map", "near", "inv"):
        show(read_state(), a[0])
    elif a[0] == "raw":
        print(json.dumps(read_state(), indent=1))
    elif a[0] == "reload":
        status = os.path.join(D, "loader.txt")
        before = os.path.getmtime(status) if os.path.exists(status) else 0
        os.makedirs(D, exist_ok=True)
        with open(os.path.join(D, "reload.txt"), "w") as f:
            f.write(str(time.time()))
        for _ in range(20):
            time.sleep(0.5)
            if os.path.exists(status) and os.path.getmtime(status) > before:
                print(open(status).read())
                break
        else:
            print("no answer from the game. Is it running, with ClaudeBot enabled and a character in the world?")
    elif a[0] == "eval":
        # python pz.py eval "<lua statements; set R = value>"
        with open(os.path.join(D, "eval.lua"), "w", encoding="utf-8") as f:
            f.write("local p = getSpecificPlayer(0)\nlocal B = ClaudeBot\nlocal R\n" + " ".join(a[1:]) + "\nClaudeBot.evalResult = R\n")
        do(["eval"])
    elif a[0] == "do":
        do([c for c in a[1:] if c != "--full"], full="--full" in a)
    else:
        print(__doc__)
