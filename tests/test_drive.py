"""python tests/test_drive.py: road routing and the drive summary (no game needed; routing
needs the game install for streets.xml)."""
import math, os, sys, tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import pz, roads

# the farm where the van sat on 2026-10-03, to the Rosewood base
pts, names, km, off = roads.route(7198, 9693, 8153, 11677)
assert len(pts) > 5 and 2.2 < km < 4, (len(pts), km)  # 2.2 km straight; was 21.6 when junctions were unlinked
assert math.dist(pts[-1], (8153, 11677)) < 40, pts[-1]
# bends are sampled: no two kept points on a curve more than ~8 tiles apart unless the road is
# straight between them (a straight stretch can be any length)
for a, b, c in zip(pts, pts[1:], pts[2:]):
    h1 = math.atan2(b[1] - a[1], b[0] - a[0]); h2 = math.atan2(c[1] - b[1], c[0] - b[0])
    turn = abs((h2 - h1 + math.pi) % (2 * math.pi) - math.pi)
    assert not (turn > math.radians(30) and math.dist(a, b) < 1), (a, b, c)
print("PASS: route %d points, %.1f km via %s" % (len(pts), km, " > ".join(names[:4])))

# drive summary from a synthetic log: 10 s along x at 36 km/h, half the time on road
d = tempfile.mkdtemp()
path = os.path.join(d, "drive_log.csv")
with open(path, "w", encoding="utf-8") as f:
    f.write("ms,x,y,heading,kmh,wheel,want,err,yaw,key,road,off\n")
    for i in range(101):
        f.write("%d,%.2f,100,0,36,0,0,%.3f,0,,%s,%s\n" % (i * 100, 100 + i * 0.5, 0.1 if i % 50 < 25 else -0.1,
                                                         "road" if i < 50 else "-", "3" if 60 <= i < 70 else "0"))
import io, contextlib
out = io.StringIO()
with contextlib.redirect_stdout(out):
    pz.drive_summary(path)
s = out.getvalue()
assert "10 s, 50 tiles" in s and "avg 36.0" in s, s
assert "on road 50%" in s and "swerves round cars 1" in s, s
assert "steering flips 4" in s, s
print("PASS: drive summary")
