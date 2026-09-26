#!/usr/bin/env python3
"""
Exports the avatar kit for bighelp's native (SwiftUI Canvas) renderer.

Reads the characters from build.py, applies the kit's CSS to every element in
every state, and writes one JSON file the app draws from:

    python3 Design/AvatarKit/tools/export_native.py

Run it after editing build.py. The output is Loopdy/Resources/AvatarKit.json.
Only the CSS features the kit uses are supported; anything else fails loudly.
"""
import importlib.util
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.dirname(HERE)
REPO = os.path.dirname(os.path.dirname(KIT))
OUT = os.path.join(REPO, "Loopdy", "Resources", "AvatarKit.json")

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("avatar_kit_build", os.path.join(HERE, "build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

SVG_NS = "{http://www.w3.org/2000/svg}"
INHERITED = {"fill", "fill-opacity", "stroke", "stroke-width", "stroke-opacity",
             "stroke-linecap", "stroke-linejoin", "font-size"}
VARS = {"--p": "@p", "--s": "@s", "--a": "@a", "--bg": "@bg", "--ink": "@ink", "--skin": "@skin"}


def fail(message):
    raise SystemExit("export_native: " + message)


def num(value):
    return round(float(value), 3)


# ---------------------------------------------------------------------------
# CSS parsing
# ---------------------------------------------------------------------------

def split_top(text, sep):
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == sep and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    parts.append(current)
    return [p.strip() for p in parts if p.strip()]


def parse_css(css):
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S)
    keyframes, rules, i = {}, [], 0
    while i < len(css):
        if css.startswith("@media", i):
            depth, j = 0, css.index("{", i)
            while True:
                if css[j] == "{":
                    depth += 1
                elif css[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            i = j + 1
            continue
        if css.startswith("@keyframes", i):
            start = css.index("{", i)
            name = css[i + len("@keyframes"):start].strip()
            depth, j = 0, start
            while True:
                if css[j] == "{":
                    depth += 1
                elif css[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            keyframes[name] = parse_keyframes(css[start + 1:j])
            i = j + 1
            continue
        brace = css.find("{", i)
        if brace < 0:
            break
        end = css.index("}", brace)
        selectors = css[i:brace].strip()
        decls = parse_decls(css[brace + 1:end])
        for selector in split_top(selectors, ","):
            rules.append((selector, decls))
        i = end + 1
    return keyframes, rules


def parse_decls(body):
    decls = {}
    for part in split_top(body, ";"):
        if ":" not in part:
            continue
        key, value = part.split(":", 1)
        decls[key.strip()] = value.replace("!important", "").strip()
    return decls


def parse_keyframes(body):
    stops = []
    for match in re.finditer(r"([^{}]+)\{([^{}]*)\}", body):
        decls = parse_decls(match.group(2))
        for sel in split_top(match.group(1), ","):
            sel = sel.strip()
            t = 0.0 if sel == "from" else 1.0 if sel == "to" else float(sel.rstrip("%")) / 100
            stop = {"t": t}
            if "transform" in decls:
                stop["tf"] = parse_transform(decls["transform"])
            if "translate" in decls:
                stop["tl"] = translate_terms(decls["translate"])
            if "opacity" in decls:
                stop["o"] = float(decls["opacity"])
            stops.append(stop)
    stops.sort(key=lambda s: s["t"])
    return stops


def parse_length(value):
    value = value.strip()
    if value.endswith("px"):
        return float(value[:-2])
    if value.endswith("deg"):
        return float(value[:-3])
    return float(value)


def parse_linear(text):
    """A CSS length expression as {symbol: coefficient}: "" constant (px), "L" per
    --look px, "P" per pointer unit (--lx/--ly), "PL" per pointer unit per --look px."""
    text = text.strip()
    if text.startswith("calc(") and text.endswith(")"):
        text = text[len("calc("):-1]
    total = {}
    for term in split_top(text.replace(" + ", "\n+").replace(" - ", "\n-"), "\n"):
        sign = 1.0
        if term.startswith("+"):
            term = term[1:].strip()
        elif term.startswith("-") and not re.match(r"-[\d.]", term):
            sign, term = -1.0, term[1:].strip()
        coefficient, symbols = sign, ""
        for factor in split_top(term, "*"):
            factor = factor.strip()
            match = re.fullmatch(r"var\((--[\w-]+)(?:,\s*(.+))?\)", factor)
            if match and match.group(1) == "--look":
                symbols += "L"
            elif match and match.group(1) in ("--lx", "--ly"):
                symbols += "P"
            elif match:
                fail("unsupported variable in length " + factor)
            else:
                coefficient *= parse_length(factor)
        key = "".join(sorted(symbols))
        total[key] = total.get(key, 0.0) + coefficient
    return total


def translate_terms(value):
    """CSS translate -> [x, x·look, x·gaze, x·gaze·look, y, y·look, y·gaze, y·gaze·look].
    `look` is the character's --look distance and `gaze` the app's −1…1 look direction."""
    parts = split_top(value, " ")
    if len(parts) == 1:
        parts.append("0")
    out = []
    for part in parts[:2]:
        terms = parse_linear(part)
        if set(terms) - {"", "L", "P", "LP"}:
            fail("unsupported translate " + value)
        out += [num(terms.get(key, 0)) for key in ("", "L", "P", "LP")]
    return out


def parse_transform(value):
    """CSS transform list -> {tx, ty, r, sx, sy} (applied translate, rotate, scale)."""
    out = {}
    if value == "none":
        return out
    for fn, args in re.findall(r"([a-zA-Z]+)\(([^)]*)\)", value):
        a = [parse_length(x) for x in re.split(r"[ ,]+", args.strip()) if x]
        if fn == "rotate":
            out["r"] = a[0]
        elif fn == "translateY":
            out["ty"] = a[0]
        elif fn == "translateX":
            out["tx"] = a[0]
        elif fn == "translate":
            out["tx"] = a[0]
            out["ty"] = a[1] if len(a) > 1 else 0
        elif fn == "scale":
            out["sx"] = a[0]
            out["sy"] = a[1] if len(a) > 1 else a[0]
        elif fn == "scaleX":
            out["sx"] = a[0]
        elif fn == "scaleY":
            out["sy"] = a[0]
        else:
            fail("unsupported transform " + fn)
    return out


def parse_svg_transform(value):
    """SVG transform attribute -> affine [a, b, c, d, e, f]."""
    import math
    matrix = [1, 0, 0, 1, 0, 0]

    def mul(m, n):
        return [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1],
                m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3],
                m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]]

    for fn, args in re.findall(r"([a-zA-Z]+)\(([^)]*)\)", value):
        a = [float(x) for x in re.split(r"[ ,]+", args.strip()) if x]
        if fn == "matrix":
            step = a
        elif fn == "rotate":
            rad = math.radians(a[0])
            cx, cy = (a[1], a[2]) if len(a) == 3 else (0, 0)
            c, s = math.cos(rad), math.sin(rad)
            step = [c, s, -s, c, cx - c * cx + s * cy, cy - s * cx - c * cy]
        elif fn == "translate":
            step = [1, 0, 0, 1, a[0], a[1] if len(a) > 1 else 0]
        elif fn == "scale":
            step = [a[0], 0, 0, a[1] if len(a) > 1 else a[0], 0, 0]
        else:
            fail("unsupported SVG transform " + fn)
        matrix = mul(matrix, step)
    return [num(x) for x in matrix]


def parse_time(value):
    value = value.strip()
    return float(value[:-2]) / 1000 if value.endswith("ms") else float(value.rstrip("s"))


def parse_animation(value):
    if value.strip() == "none":
        return None
    anim = {"dur": 0.0, "delay": 0.0, "ease": "ease", "dir": "normal", "iter": 1}
    times = []
    for token in split_top(value, " "):
        if re.fullmatch(r"-?[\d.]+m?s", token):
            seconds = float(token[:-2]) / 1000 if token.endswith("ms") else float(token[:-1])
            times.append(seconds)
        elif token in ("ease", "linear", "ease-in", "ease-out", "ease-in-out") or token.startswith(("cubic-bezier", "steps")):
            anim["ease"] = token
        elif token == "infinite":
            anim["iter"] = 0
        elif token in ("alternate", "reverse", "alternate-reverse", "normal"):
            anim["dir"] = token
        elif re.fullmatch(r"[\d.]+", token):
            anim["iter"] = float(token)
        else:
            anim["name"] = token
    if times:
        anim["dur"] = times[0]
    if len(times) > 1:
        anim["delay"] = times[1]
    return anim


# ---------------------------------------------------------------------------
# Selectors
# ---------------------------------------------------------------------------

COMPOUND = re.compile(r"(\*|[a-zA-Z]+)?((?:\.[\w-]+|\[[^\]]+\]|:nth-child\(\d+\))*)")


def parse_selector(selector):
    """-> list of (combinator, compound) from left to right."""
    parts, combinator = [], " "
    raw = re.split(r"(\s*[>+]\s*|\s+)", selector.strip())
    for piece in raw:
        if not piece:
            continue
        stripped = piece.strip()
        if stripped in (">", "+"):
            combinator = stripped
            continue
        if not stripped:
            combinator = " " if combinator not in (">", "+") else combinator
            continue
        parts.append((combinator, parse_compound(stripped)))
        combinator = " "
    return parts


def parse_compound(text):
    match = COMPOUND.fullmatch(text)
    if not match:
        fail("unsupported selector " + text)
    tag = match.group(1)
    classes, attrs, nth = [], [], None
    for item in re.findall(r"\.[\w-]+|\[[^\]]+\]|:nth-child\(\d+\)", match.group(2)):
        if item.startswith("."):
            classes.append(item[1:])
        elif item.startswith("["):
            inner = item[1:-1]
            if "=" in inner:
                key, value = inner.split("=", 1)
                attrs.append((key, value.strip('"')))
            else:
                attrs.append((inner, None))
        else:
            nth = int(item[len(":nth-child("):-1])
    return {"tag": None if tag in (None, "*") else tag, "classes": classes, "attrs": attrs, "nth": nth,
            "specificity": (len(classes) + len(attrs) + (1 if nth else 0), 1 if tag not in (None, "*") else 0)}


def specificity(parts):
    a = sum(c["specificity"][0] for _, c in parts)
    b = sum(c["specificity"][1] for _, c in parts)
    return (a, b)


class Node:
    def __init__(self, element, parent, index):
        self.tag = element.tag.replace(SVG_NS, "")
        self.attrs = dict(element.attrib)
        self.classes = self.attrs.get("class", "").split()
        self.parent = parent
        self.index = index  # 1-based among element siblings
        self.text = (element.text or "").strip()
        self.children = []
        self.previous = None

    def attr(self, key, state):
        if key == "data-state":
            return state
        return self.attrs.get(key)


def matches_compound(node, compound, state):
    if compound["tag"] and node.tag != compound["tag"]:
        return False
    if any(c not in node.classes for c in compound["classes"]):
        return False
    for key, value in compound["attrs"]:
        actual = node.attr(key, state)
        if actual is None or (value is not None and actual != value):
            return False
    if compound["nth"] and node.index != compound["nth"]:
        return False
    return True


def matches(node, parts, state):
    if not parts:
        return True
    combinator, compound = parts[-1]
    if not matches_compound(node, compound, state):
        return False
    rest = parts[:-1]
    if not rest:
        return True
    if combinator == ">":
        return node.parent is not None and matches(node.parent, rest, state)
    if combinator == "+":
        return node.previous is not None and matches(node.previous, rest, state)
    ancestor = node.parent
    while ancestor is not None:
        if matches(ancestor, rest, state):
            return True
        ancestor = ancestor.parent
    return False


# ---------------------------------------------------------------------------
# Geometry (fill-box bounds for transform origins)
# ---------------------------------------------------------------------------

PATH_ARGS = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "Q": 4, "A": 7, "Z": 0}


def arc_points(start, end, rx, ry, rotation, large, sweep):
    """Points along an SVG elliptical arc (SVG 1.1, appendix F.6)."""
    import math
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0 or start == end:
        return [end]
    phi = math.radians(rotation)
    cp, sp = math.cos(phi), math.sin(phi)
    dx, dy = (start[0] - end[0]) / 2, (start[1] - end[1]) / 2
    x1, y1 = cp * dx + sp * dy, -sp * dx + cp * dy
    lam = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
    if lam > 1:
        rx, ry = rx * math.sqrt(lam), ry * math.sqrt(lam)
    num_ = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    coef = (-1 if large == sweep else 1) * math.sqrt(max(0, num_ / den))
    cxp, cyp = coef * rx * y1 / ry, -coef * ry * x1 / rx
    cx = cp * cxp - sp * cyp + (start[0] + end[0]) / 2
    cy = sp * cxp + cp * cyp + (start[1] + end[1]) / 2
    ux, uy = (x1 - cxp) / rx, (y1 - cyp) / ry
    vx, vy = (-x1 - cxp) / rx, (-y1 - cyp) / ry
    theta = math.atan2(uy, ux)
    delta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    if sweep and delta < 0:
        delta += 2 * math.pi
    out = []
    for i in range(1, 33):
        a = theta + delta * i / 32
        out.append((cx + rx * cp * math.cos(a) - ry * sp * math.sin(a), cy + rx * sp * math.cos(a) + ry * cp * math.sin(a)))
    return out


def path_points(d):
    """Endpoints and control points of a path (arcs sampled), for bounds."""
    tokens = re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?", d)
    points, i, command = [], 0, "M"
    current = start = (0.0, 0.0)
    while i < len(tokens):
        if tokens[i].isalpha():
            command = tokens[i]
            i += 1
            if command in "Zz":
                current = start
                continue
        upper = command.upper()
        if upper not in PATH_ARGS:
            fail("unsupported path command " + command)
        count = PATH_ARGS[upper]
        args = [float(x) for x in tokens[i:i + count]]
        i += count
        rel = command.islower()
        ox, oy = current if rel else (0.0, 0.0)
        if upper == "H":
            current = (args[0] + (current[0] if rel else 0), current[1])
        elif upper == "V":
            current = (current[0], args[0] + (current[1] if rel else 0))
        elif upper == "A":
            end = (args[5] + ox, args[6] + oy)
            points.extend(arc_points(current, end, args[0], args[1], args[2], args[3] != 0, args[4] != 0))
            current = end
        else:
            pairs = [(args[j] + ox, args[j + 1] + oy) for j in range(0, count, 2)]
            points.extend(pairs[:-1])
            current = pairs[-1]
        points.append(current)
        if upper == "M":
            start = current
            command = "l" if rel else "L"
    return points


def apply(matrix, point):
    a, b, c, d, e, f = matrix
    x, y = point
    return (a * x + c * y + e, b * x + d * y + f)


def local_bounds(node):
    """Bounds in the node's own coordinates (before its transform attribute)."""
    t, a = node.tag, node.attrs
    if t == "path":
        points = path_points(a["d"])
    elif t in ("circle", "ellipse"):
        rx = float(a.get("rx", a.get("r")))
        ry = float(a.get("ry", a.get("r")))
        cx, cy = float(a["cx"]), float(a["cy"])
        points = [(cx - rx, cy - ry), (cx + rx, cy + ry)]
    elif t == "rect":
        x, y, w, h = float(a["x"]), float(a["y"]), float(a["width"]), float(a["height"])
        points = [(x, y), (x + w, y + h)]
    elif t == "text":
        size = float(a.get("font-size", 12))
        x, y = float(a["x"]), float(a["y"])
        points = [(x, y - size * 0.75), (x + size * 0.62 * max(len(node.text), 1), y)]
    else:
        points = []
        for child in node.children:
            box = local_bounds(child)
            if box is None:
                continue
            corners = [(box[0], box[1]), (box[2], box[1]), (box[0], box[3]), (box[2], box[3])]
            if "transform" in child.attrs:
                matrix = parse_svg_transform(child.attrs["transform"])
                corners = [apply(matrix, p) for p in corners]
            points.extend(corners)
    if not points:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return (min(xs), min(ys), max(xs), max(ys))


def resolve_origin(node, value, box_mode):
    box = local_bounds(node) or (0, 0, 200, 200)
    if box_mode == "view-box":
        box = (0, 0, 200, 200)
    x0, y0, x1, y1 = box
    words = value.split()
    if value == "center":
        words = ["50%", "50%"]
    if len(words) == 1:
        words.append("50%")
    out = []
    for word, lo, hi in ((words[0], x0, x1), (words[1], y0, y1)):
        if word.endswith("%"):
            out.append(lo + (hi - lo) * float(word[:-1]) / 100)
        elif word in ("left", "top"):
            out.append(lo)
        elif word in ("right", "bottom"):
            out.append(hi)
        elif word == "center":
            out.append((lo + hi) / 2)
        else:
            out.append(lo + parse_length(word))
    return [num(out[0]), num(out[1])]


# ---------------------------------------------------------------------------
# Cascade and export
# ---------------------------------------------------------------------------

def paint(value, root_vars):
    value = value.strip()
    if value == "none":
        return "none"
    match = re.fullmatch(r"var\((--[\w-]+)(?:,\s*(.+))?\)", value)
    if match:
        name, fallback = match.group(1), match.group(2)
        if name in VARS:
            return VARS[name]
        if name in root_vars:
            return paint(root_vars[name], root_vars)
        if fallback:
            return paint(fallback, root_vars)
        fail("unknown color variable " + name)
    if re.fullmatch(r"#[0-9A-Fa-f]{3}", value):
        return "#" + "".join(ch * 2 for ch in value[1:]).upper()
    if re.fullmatch(r"#[0-9A-Fa-f]{6}", value):
        return value.upper()
    fail("unsupported paint " + value)


def cascade(node, state, rules, inherited):
    """Computed style for one element in one state."""
    presentation = {k: v for k, v in node.attrs.items()
                    if k in ("fill", "stroke", "stroke-width", "opacity", "font-size", "stroke-linecap")}
    candidates = []
    for order, (parts, spec, decls) in enumerate(rules):
        if matches(node, parts, state):
            candidates.append((spec, order, decls))
    candidates.sort(key=lambda c: (c[0], c[1]))
    style = dict(presentation)
    for _, _, decls in candidates:
        for key, value in decls.items():
            if key == "animation":
                style.pop("animation-duration", None)
                style.pop("animation-delay", None)
            style[key] = value
    if "style" in node.attrs:
        for key, value in parse_decls(node.attrs["style"]).items():
            if key == "animation":
                style.pop("animation-duration", None)
                style.pop("animation-delay", None)
            style[key] = value
    computed = {k: v for k, v in inherited.items()}
    for key in INHERITED:
        if key in style:
            computed[key] = style[key]
    return style, computed


def export_character(character, shared_rules, keyframes):
    svg_text = build.build_svg(character)
    root_element = ET.fromstring(svg_text)
    bits = character.get("family") == "bits"
    extra_css = (build.BITS_CSS if bits else "") + build.compact(character["css"])
    char_keyframes, char_rules = parse_css(extra_css)
    keyframes.update(char_keyframes)
    root_vars = {}
    for selector, decls in parse_css(build.vars_css(character))[1]:
        root_vars.update({k: v for k, v in decls.items() if k.startswith("--")})
    rules = []
    for selector, decls in shared_rules + char_rules:
        parts = parse_selector(selector)
        rules.append((parts, specificity(parts), decls))

    look = 3.0
    for selector, decls in char_rules:
        if selector.strip() == ".bh-av--" + character["id"] and "--look" in decls:
            look = parse_length(decls["--look"])

    def build_tree(element, parent, index):
        node = Node(element, parent, index)
        previous = None
        position = 0
        for child in element:
            tag = child.tag.replace(SVG_NS, "")
            if tag in ("style", "title"):
                continue
            position += 1
            child_node = build_tree(child, node, position)
            child_node.previous = previous
            previous = child_node
            node.children.append(child_node)
        return node

    root = build_tree(root_element, None, 1)
    used = set()
    # Bits swap face parts with root attributes; each part records which options show it.
    options = {"data-eyes": build.EYE_STYLES, "data-mouth": build.MOUTH_STYLES,
               "data-acc": build.ACCESSORIES, "data-cheeks": ["on", "off"]} if bits else {}
    option_keys = {"data-eyes": "eyes", "data-mouth": "mouth", "data-acc": "acc", "data-cheeks": "cheeks"}

    def with_root(changes, fn):
        saved = {key: root.attrs.get(key) for key in changes}
        root.attrs.update(changes)
        try:
            return fn()
        finally:
            root.attrs.update(saved)

    def displayed(node):
        return cascade(node, "idle", rules, {})[0].get("display") != "none"

    def face_condition(node):
        when, showing = {}, {}
        for attribute, values in options.items():
            allowed = [v for v in values if with_root({attribute: v}, lambda: displayed(node))]
            if not allowed:
                allowed = values  # hidden by another option; that one decides
            if allowed != values:
                when[option_keys[attribute]] = allowed
            showing[attribute] = allowed[0]
        return when, showing

    def export(node, inherited_by_state):
        out = {"t": node.tag}
        a = node.attrs
        if node.tag == "path":
            out["d"] = a["d"]
        elif node.tag in ("circle", "ellipse"):
            out["cx"], out["cy"] = num(a["cx"]), num(a["cy"])
            out["rx"] = num(a.get("rx", a.get("r")))
            out["ry"] = num(a.get("ry", a.get("r")))
        elif node.tag == "rect":
            out["x"], out["y"] = num(a["x"]), num(a["y"])
            out["w"], out["h"] = num(a["width"]), num(a["height"])
            out["rx"] = num(a.get("rx", 0))
        elif node.tag == "text":
            out["x"], out["y"] = num(a["x"]), num(a["y"])
            out["text"] = node.text
        if "transform" in a:
            out["m"] = parse_svg_transform(a["transform"])
        if "bh-bg" in node.classes:
            out["bg"] = True
        if "bh-body" in node.classes:
            out["body"] = True
        if "bh-rig" in node.classes:
            out["rig"] = True

        when, showing = face_condition(node) if options else ({}, {})
        if when:
            out["when"] = when
        states = {}
        next_inherited = {}
        for state in build.STATES:
            style, computed = with_root(showing, lambda: cascade(node, state, rules, inherited_by_state[state]))
            next_inherited[state] = computed
            entry = {}
            if style.get("display") == "none":
                entry["hide"] = True
            if "opacity" in style:
                entry["o"] = num(style["opacity"])
            animation = parse_animation(style["animation"]) if "animation" in style else None
            if animation and "animation-duration" in style:
                animation["dur"] = parse_time(style["animation-duration"])
            if animation and "animation-delay" in style:
                animation["delay"] = parse_time(style["animation-delay"])
            if animation:
                if animation.get("name") not in keyframes:
                    fail("unknown keyframes %r on %s" % (animation.get("name"), node.classes))
                used.add(animation["name"])
                entry["an"] = animation
            transform = parse_transform(style["transform"]) if "transform" in style else {}
            if transform:
                entry["tf"] = transform
            if "translate" in style:
                entry["tl"] = translate_terms(style["translate"])
            if animation or transform:
                if "transform" in a and animation and any("tf" in s for s in keyframes[animation["name"]]):
                    fail("element with a transform attribute is also transformed by CSS: %s" % node.classes)
                box_mode = "fill-box"
                if style.get("transform-box") == "view-box":
                    box_mode = "view-box"
                entry["org"] = resolve_origin(node, style.get("transform-origin", "center"), box_mode)
            if node.tag in ("path", "circle", "ellipse", "rect", "text"):
                fill = computed.get("fill", "#000000")
                entry["f"] = paint(fill, root_vars)
                if "fill-opacity" in computed:
                    entry["fo"] = num(computed["fill-opacity"])
                if computed.get("stroke", "none") != "none":
                    entry["s"] = paint(computed["stroke"], root_vars)
                    entry["sw"] = num(parse_length(computed.get("stroke-width", "1")))
                    if "stroke-opacity" in computed:
                        entry["so"] = num(computed["stroke-opacity"])
                    entry["cap"] = computed.get("stroke-linecap", "butt")
                    entry["join"] = computed.get("stroke-linejoin", "miter")
                if node.tag == "text":
                    entry["fs"] = num(parse_length(computed.get("font-size", "12")))
            states[state] = entry
        idle = states["idle"]
        out["st"] = {"idle": idle}
        for state in build.STATES[1:]:
            if states[state] != idle:
                out["st"][state] = states[state]
        if node.children:
            out["k"] = [export(child, next_inherited) for child in node.children]
        return out

    inherited = {state: {} for state in build.STATES}
    tree = export(root, inherited)
    colors = character["colors"]
    return {
        "id": character["id"],
        "name": character["name"],
        "role": character["role"],
        "family": character.get("family", "classic"),
        **({"face": character["face"]} if bits else {}),
        "look": look,
        "colors": {"p": colors["p"], "s": colors["s"], "a": colors["a"], "bg": colors["bg"],
                   "ink": "#2A2238", "skin": colors.get("skin", "#F6CFB0")},
        "tree": tree,
    }, used


def main():
    shared_keyframes, shared_rules = parse_css(build.compact(build.SHARED_CSS))
    keyframes = dict(shared_keyframes)
    characters, used = [], set()
    for character in build.CHARACTERS:
        exported, names = export_character(character, shared_rules, keyframes)
        characters.append(exported)
        used |= names
    themes = {key: {"name": t["name"], "colors": t["colors"]} for key, t in build.THEMES.items()}
    payload = {
        "version": 1,
        "states": build.STATES,
        "themes": [{"id": key, **value} for key, value in themes.items()],
        "keyframes": {name: keyframes[name] for name in sorted(used)},
        "characters": characters,
    }
    with open(OUT, "w") as f:
        json.dump(payload, f, separators=(",", ":"))
        f.write("\n")
    print("exported %d characters, %d animations -> %s" % (len(characters), len(used), os.path.relpath(OUT, REPO)))


if __name__ == "__main__":
    main()
