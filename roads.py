"""Road routing from the game's own street map (the same data pzmap.org draws as its
street overlay): media/maps/Muldraugh, KY/streets.xml, every street as a named polyline in
world tiles. `route()` returns waypoints that follow the roads, for the `drive` command.
"""
import heapq
import math
import os
import xml.etree.ElementTree as ET

STREETS = r"C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid\media\maps\Muldraugh, KY\streets.xml"
STEP = 2.0   # sample each street every STEP tiles
JOIN = 5.0   # samples of different polylines this close are a junction

_graph = None


def load(path=STREETS):
    streets = []
    for s in ET.parse(path).getroot():
        pts = [(float(p.get("x")), float(p.get("y"))) for p in s.iter("point")]
        name = s.get("name") or "?"
        # streets.xml has the railroads too; a van can't use them
        if len(pts) >= 2 and "Railroad" not in name and "Branch Line" not in name:
            streets.append((name, float(s.get("width") or 6), pts))
    return streets


def build(streets):
    nodes, names, adj, sid, ends = [], [], {}, [], {}

    def add(x, y, name, k):
        nodes.append((x, y)); names.append(name); sid.append(k); adj[len(nodes) - 1] = []
        return len(nodes) - 1

    def link(a, b):
        d = math.dist(nodes[a], nodes[b])
        adj[a].append((b, d)); adj[b].append((a, d))

    for k, (name, w, pts) in enumerate(streets):
        prev = first = None
        for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
            n = max(1, int(math.dist((x0, y0), (x1, y1)) / STEP))
            for j in range(0 if prev is None else 1, n + 1):
                i = add(x0 + (x1 - x0) * j / n, y0 + (y1 - y0) * j / n, name, k)
                if prev is not None: link(prev, i)
                if first is None: first = i
                prev = i
        ends[first] = ends[prev] = True
    width = [streets[k][1] for k in sid]
    # junctions: link nearby samples of different polylines (one road is often several
    # polylines that meet end to end). A road that ends at a wide one stops at its edge, about
    # half its width from its centreline, so a polyline's END reaches that far.
    cell, grid = 10.0, {}
    for i, (x, y) in enumerate(nodes):
        grid.setdefault((int(x // cell), int(y // cell)), []).append(i)
    for i, (x, y) in enumerate(nodes):
        cx, cy = int(x // cell), int(y // cell)
        for gx in (cx - 1, cx, cx + 1):
            for gy in (cy - 1, cy, cy + 1):
                for j in grid.get((gx, gy), ()):
                    if j <= i or sid[j] == sid[i]: continue
                    r = JOIN
                    if i in ends or j in ends: r = max(JOIN, max(width[i], width[j]) / 2 + 1.5)
                    if math.dist(nodes[i], nodes[j]) <= r:
                        link(i, j)
    return nodes, names, adj, grid


def graph():
    global _graph
    if _graph is None:
        _graph = build(load())
    return _graph


def nearest(x, y):
    nodes, names, _adj, _grid = graph()
    i = min(range(len(nodes)), key=lambda k: (nodes[k][0] - x) ** 2 + (nodes[k][1] - y) ** 2)
    return i, math.dist(nodes[i], (x, y))


def route(x0, y0, x1, y1):
    """-> (waypoints [(x, y)], street names in order, road km) or raises ValueError"""
    nodes, names, adj, _ = graph()
    s, ds = nearest(x0, y0)
    g, dg = nearest(x1, y1)
    if ds > 40: raise ValueError("start is %.0f tiles from the nearest road" % ds)
    best, prev, pq = {s: 0.0}, {}, [(math.dist(nodes[s], nodes[g]), 0.0, s)]
    while pq:
        _f, c, i = heapq.heappop(pq)
        if i == g: break
        if c > best.get(i, 1e18): continue
        for j, d in adj[i]:
            nc = c + d
            if nc < best.get(j, 1e18):
                best[j], prev[j] = nc, i
                heapq.heappush(pq, (nc + math.dist(nodes[j], nodes[g]), nc, j))
    if g not in best: raise ValueError("no road connects these points")
    path = [g]
    while path[-1] != s: path.append(prev[path[-1]])
    path.reverse()
    # keep the corners (heading change > 12 degrees), a point every ~8 tiles along a bend
    # (so the car follows the arc instead of cutting it), and the end
    pts = [nodes[i] for i in path]
    keep = [pts[0]]
    for a, b, c in zip(pts, pts[1:], pts[2:]):
        h1 = math.atan2(b[1] - a[1], b[0] - a[0]); h2 = math.atan2(c[1] - b[1], c[0] - b[0])
        turn = abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi)
        gap = math.dist(b, keep[-1])
        if (turn > math.radians(12) and gap > 3) or (turn > math.radians(3) and gap > 8): keep.append(b)
    keep.append(pts[-1])
    keep = keep[1:] if math.dist(keep[0], (x0, y0)) < 4 and len(keep) > 1 else keep
    order = []
    for i in path:
        if not order or order[-1] != names[i]: order.append(names[i])
    return [(round(x), round(y)) for x, y in keep], order, best[g] / 1000, dg


def streets_near(x, y, r=60):
    out = []
    for name, w, pts in load():
        d = min(math.dist(p, (x, y)) for p in pts)
        if d <= r: out.append((d, name))
    return sorted(set(out))
