#!/usr/bin/env python3
"""Emit expected values straight out of the Python daemon this plugin replaces.

The daemon source in ../bin is imported and called directly rather than having
its logic restated here, so the test compares the JS port against the real
implementation and cannot drift from it.
"""

import importlib.util
import importlib.machinery
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DAEMON = os.path.join(HERE, "..", "bin", "tiny-dfr-workspace")

# The daemon has no .py extension, so the loader has to be named explicitly.
loader = importlib.machinery.SourceFileLoader("dfr", DAEMON)
spec = importlib.util.spec_from_loader("dfr", loader)
dfr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dfr)


def rows(count, active):
    """The daemon builds rows inside render(); drive it with a bare template."""
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write("@WORKSPACES@")
        tmp = f.name
    old_ws, old_tpl = dfr.WORKSPACES, dfr.TEMPLATE
    try:
        dfr.WORKSPACES = tuple(range(1, count + 1))
        dfr.TEMPLATE = tmp
        return dfr.render(active)
    finally:
        dfr.WORKSPACES, dfr.TEMPLATE = old_ws, old_tpl
        os.unlink(tmp)


def battery_svg(pct, charging):
    """write_battery_icon() writes to a path; capture what it wrote."""
    with tempfile.NamedTemporaryFile(suffix=".svg", delete=False) as f:
        tmp = f.name
    old = dfr.BATTERY_SVG
    try:
        dfr.BATTERY_SVG = tmp
        dfr.write_battery_icon(pct, charging)
        with open(tmp) as f:
            return f.read()
    finally:
        dfr.BATTERY_SVG = old
        os.unlink(tmp)


def update_svg(available):
    with tempfile.NamedTemporaryFile(suffix=".svg", delete=False) as f:
        tmp = f.name
    old = dfr.UPDATE_SVG
    try:
        dfr.UPDATE_SVG = tmp
        dfr.write_update_icon(available)
        with open(tmp) as f:
            return f.read()
    finally:
        dfr.UPDATE_SVG = old
        os.unlink(tmp)


def render_template(text, count, active):
    """Render `text` through the daemon's own render()."""
    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write(text)
        tmp = f.name
    old_ws, old_tpl = dfr.WORKSPACES, dfr.TEMPLATE
    try:
        dfr.WORKSPACES = tuple(range(1, count + 1))
        dfr.TEMPLATE = tmp
        return dfr.render(active)
    finally:
        dfr.WORKSPACES, dfr.TEMPLATE = old_ws, old_tpl
        os.unlink(tmp)


def bucket(pct, charging):
    """The daemon's bucket is a tuple; the JS joins it with '/'.

    The bucket is an opaque change-detection key -- it is only ever compared
    against the previous bucket and never written anywhere -- so the two
    implementations only have to agree on *which inputs collide*, not on the
    spelling. Python renders a bool as "True" and JS as "true"; lowercasing is
    a bijection, so exact comparison after it still tests the real property.
    """
    b = dfr.battery_bucket((pct, charging))
    return "/".join(str(x).lower() if isinstance(x, bool) else str(x) for x in b)


def read_flag(text):
    with tempfile.NamedTemporaryFile("w", suffix=".state", delete=False) as f:
        f.write(text)
        tmp = f.name
    try:
        return dfr.read_flag(tmp)
    finally:
        os.unlink(tmp)


# Boundaries that matter: 5% (amber->red) and 20% (green->amber), the charging
# override at each, and the ends of the range.
PCTS = [0, 1, 4, 5, 6, 19, 20, 21, 50, 99, 100]

template_in = open(
    os.path.join(HERE, "..", "system", "etc", "tiny-dfr",
                 "config.template.toml")).read()

out = {
    "workspaceRows": [
        {"count": c, "active": a, "out": rows(c, a)}
        for c in (3, 5, 9)
        # -1 stands for "no workspace focused": no row should be a pill.
        for a in list(range(1, c + 1)) + [-1]
    ],
    "batteryColour": [
        {"pct": p, "charging": ch, "out": dfr.battery_colour(p, ch)}
        for p in PCTS for ch in (True, False)
    ],
    "batteryBucket": [
        {"pct": p, "charging": ch, "out": bucket(p, ch)}
        for p in PCTS for ch in (True, False)
    ],
    "batterySvg": [
        {"pct": p, "charging": ch, "out": battery_svg(p, ch)}
        for p in PCTS for ch in (True, False)
    ],
    "updateSvg": [
        {"available": a, "out": update_svg(a)} for a in (True, False)
    ],
    "parseBattery": [],
    "readFlag": [
        {"text": t, "out": read_flag(t)}
        for t in ("1", "0", "1\n", "0\n", " 1 ", "", "x", "2")
    ],
    "template": {
        "input": template_in,
        "out": render_template(template_in, 5, 3),
    },
}


# parse_battery has no single function in the daemon -- read_battery() reads
# sysfs directly -- so drive it through a fake BATTERY_DIR.
def parse_battery(status, now, full, capacity):
    d = tempfile.mkdtemp()
    for name, val in (("status", status), ("charge_now", now),
                      ("charge_full", full), ("capacity", capacity)):
        if val is not None:
            with open(os.path.join(d, name), "w") as f:
                f.write(val)
    old = dfr.BATTERY_DIR
    try:
        dfr.BATTERY_DIR = d
        r = dfr.read_battery()
        return None if r is None else [r[0], r[1]]
    finally:
        dfr.BATTERY_DIR = old
        for name in os.listdir(d):
            os.unlink(os.path.join(d, name))
        os.rmdir(d)


out["parseBattery"] = [
    {"status": s, "now": n, "full": f, "capacity": c,
     "out": parse_battery(s, n, f, c)}
    for (s, n, f, c) in [
        ("Discharging", "5000000", "10000000", "50"),
        ("Charging", "5000000", "10000000", "50"),
        ("Full", "10000000", "10000000", "100"),
        # A worn cell whose charge_full has drifted below true capacity: the
        # raw ratio is 101%, which must clamp to 100.
        ("Full", "10100000", "10000000", "100"),
        # charge_* missing entirely -> fall back to `capacity`.
        ("Discharging", None, None, "61"),
        # charge_full of zero must not divide -> fall back to `capacity`.
        ("Discharging", "5000000", "0", "44"),
        ("Unknown", None, None, None),
    ]
]

json.dump(out, sys.stdout)
