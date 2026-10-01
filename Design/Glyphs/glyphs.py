"""bighelp line glyphs: 24-pt grid, 2-pt round strokes, one filled "bighelp dot" where it helps.

Edit a glyph here, then regenerate the app's template assets:

    python3 Design/Glyphs/glyphs.py /tmp/glyphs && python3 Design/Glyphs/export_assets.py /tmp/glyphs

`/tmp/glyphs/_sheet.svg` is a contact sheet for review (Quick Look renders it). Agents are
drawn as the brand's soft orb with two eyes gazing up; the app maps SF Symbol names to these
in `BighelpGlyph`.
"""
import math
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
SW = 2  # stroke width on the 24 grid


def dot(x, y, r=1.35):
    return f'<circle cx="{x}" cy="{y}" r="{r}" fill="#000" stroke="none"/>'


def gear(cx=12, cy=12, teeth=6, r_out=9.2, r_in=7.0):
    # Broad rounded teeth: each tooth spans ~40% of its slot.
    pts = []
    slot = 2 * math.pi / teeth
    for i in range(teeth):
        a = slot * i - math.pi / 2
        for frac, r in ((-0.30, r_in), (-0.17, r_out), (0.17, r_out), (0.30, r_in)):
            ang = a + frac * slot
            pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + " Z"
    return f'<path d="{d}"/><circle cx="{cx}" cy="{cy}" r="2.8"/>'


def bubble(x, y, w, h, r=4.2, tail="left"):
    # Rounded speech bubble with a small tail at the bottom corner.
    x2, y2 = x + w, y + h
    if tail == "left":
        return (f'<path d="M{x + r} {y} H{x2 - r} A{r} {r} 0 0 1 {x2} {y + r} V{y2 - r} '
                f'A{r} {r} 0 0 1 {x2 - r} {y2} H{x + 5.2} L{x + 1.4} {y2 + 2.6} '
                f'L{x + 1.9} {y2 - 0.4} A{r} {r} 0 0 1 {x} {y2 - r} V{y + r} A{r} {r} 0 0 1 {x + r} {y} Z"/>')
    return (f'<path d="M{x + r} {y} H{x2 - r} A{r} {r} 0 0 1 {x2} {y + r} V{y2 - r} '
            f'A{r} {r} 0 0 1 {x2 - 1.9} {y2 - 0.4} L{x2 - 1.4} {y2 + 2.6} L{x2 - 5.2} {y2} '
            f'H{x + r} A{r} {r} 0 0 1 {x} {y2 - r} V{y + r} A{r} {r} 0 0 1 {x + r} {y} Z"/>')


def blob(cx, cy, s=1.0):
    # An agent: a soft orb with two eyes gazing up.
    r = 7.2 * s
    return (f'<path d="M{cx - r} {cy + 0.8 * s} C{cx - r} {cy - 5.2 * s} {cx - 4 * s} {cy - r} {cx} {cy - r} '
            f'C{cx + 4 * s} {cy - r} {cx + r} {cy - 5.2 * s} {cx + r} {cy + 0.8 * s} '
            f'C{cx + r} {cy + 5 * s} {cx + 4.2 * s} {cy + r - 0.4 * s} {cx} {cy + r - 0.4 * s} '
            f'C{cx - 4.2 * s} {cy + r - 0.4 * s} {cx - r} {cy + 5 * s} {cx - r} {cy + 0.8 * s} Z"/>'
            + dot(cx - 2.3 * s, cy - 1.6 * s, 1.15 * s) + dot(cx + 2.3 * s, cy - 1.6 * s, 1.15 * s))


def doc(x=5, y=3, w=14, h=18, fold=4.5, r=2.6):
    return (f'<path d="M{x + w - fold} {y} H{x + r} A{r} {r} 0 0 0 {x} {y + r} V{y + h - r} '
            f'A{r} {r} 0 0 0 {x + r} {y + h} H{x + w - r} A{r} {r} 0 0 0 {x + w} {y + h - r} V{y + fold} Z"/>'
            f'<path d="M{x + w - fold} {y} V{y + fold - 1.2} A1.2 1.2 0 0 0 {x + w - fold + 1.2} {y + fold} H{x + w}"/>')


def folder(x=3, y=5, w=18, h=14, r=2.6):
    return (f'<path d="M{x} {y + r} A{r} {r} 0 0 1 {x + r} {y} H{x + 5.2} L{x + 7.6} {y + 2.4} H{x + w - r} '
            f'A{r} {r} 0 0 1 {x + w} {y + 2.4 + r} V{y + h - r} A{r} {r} 0 0 1 {x + w - r} {y + h} H{x + r} '
            f'A{r} {r} 0 0 1 {x} {y + h - r} Z"/>')


GLYPHS = {
    # ☰ menu
    "host": '<rect x="3" y="4" width="18" height="12.5" rx="3"/><path d="M12 16.5V20M8.5 20.2h7"/>' + dot(12, 10.25),
    "plus": '<path d="M12 5v14M5 12h14"/>',
    "folder": folder(),
    "compose": '<path d="M11 4.5H7.5A3 3 0 0 0 4.5 7.5v9a3 3 0 0 0 3 3h9a3 3 0 0 0 3-3V13"/>'
               '<path d="M17.3 3.7a2.1 2.1 0 0 1 3 3L13.4 13.6 9.8 14.3l.7-3.6Z"/>',
    "group": blob(8.6, 13.4, 0.76) + '<path d="M13.2 6.6a5.6 5.6 0 0 1 8.3 4.9c0 3.3-2.3 5.6-5.5 5.6"/>' + dot(16.2, 10.6, 0.9) + dot(19.1, 10.6, 0.9),
    "chats": bubble(2.8, 4, 12.4, 9.2) + '<path d="M18.4 8.6a3.2 3.2 0 0 1 2.8 3.2v4.1a3 3 0 0 1-.9 2.2l.6 2.1-2.5-.9H13a3.3 3.3 0 0 1-3-1.9"/>',
    "projects": '<path d="M6.5 5.5V5a2 2 0 0 1 2-2h3.3l1.9 1.9H19a2 2 0 0 1 2 2V13"/>' + folder(3, 7.5, 15, 12.5),
    "simple": blob(12, 10, 0.95) + '<ellipse cx="12" cy="20.2" rx="5.2" ry="1.1"/>',
    "agents": blob(12, 12.3, 1.12),
    "scheduled": '<path d="M20.4 12a8.4 8.4 0 1 1-2.5-6"/><path d="M18.4 2.8v3.6h-3.6"/><path d="M12 7.6V12l2.8 2"/>',
    "kanban": '<rect x="3.5" y="4" width="4.6" height="16" rx="2.3"/><rect x="9.7" y="4" width="4.6" height="11" rx="2.3"/>'
              '<rect x="15.9" y="4" width="4.6" height="7" rx="2.3"/>' + dot(18.2, 15.6, 1.35),
    "usage": '<path d="M4 16.5a8 8 0 1 1 16 0"/><path d="M12 16.5l3.6-4.6"/>' + dot(12, 16.5, 1.6) + '<path d="M4 19.5h16"/>',
    "tools": '<rect x="3.5" y="3.5" width="7" height="7" rx="2.2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2.2"/>'
             '<rect x="3.5" y="13.5" width="7" height="7" rx="2.2"/><circle cx="17" cy="7" r="3.5"/>',
    "settings": gear(),
    # Hermes Tools and Settings
    "bell": '<path d="M6 16.8V11a6 6 0 0 1 12 0v5.8l1.5 1.7h-15Z"/><path d="M10 21h4"/>',
    "bellDot": '<path d="M5.5 16.8V11a6 6 0 0 1 8.6-5.4M17.9 10.4c.1.2.1.4.1.6v5.8l1.5 1.7h-15l1-1.7"/><path d="M10 21h4"/>' + dot(18.2, 5.8, 2.1),
    "checklist": '<path d="M4 6.5l1.6 1.6L8.6 5M4 15.5l1.6 1.6 3-3.1M12 6.8h8M12 15.8h8"/>',
    "doc": doc(),
    "docRich": doc() + '<path d="M8.5 16.5l2.3-2.8 1.9 2 1.5-1.6 1.8 2.4"/>' + dot(9.7, 10.8, 1.2),
    "book": '<path d="M12 6.4c-2-1.4-4.8-2-8-1.8v13.5c3.2-.2 6 .4 8 1.8 2-1.4 4.8-2 8-1.8V4.6c-3.2-.2-6 .4-8 1.8Z"/><path d="M12 6.4v13.5"/>',
    "bookClosed": '<path d="M5 18.5V6a3 3 0 0 1 3-3h11v14.5H8a3 3 0 0 0-3 3Zm0 0A2.5 2.5 0 0 0 7.5 21H19"/><path d="M14 3v6l-2-1.4L10 9V3"/>',
    "chip": '<rect x="6" y="6" width="12" height="12" rx="2.8"/><rect x="9.5" y="9.5" width="5" height="5" rx="1.2"/>'
            '<path d="M9.5 3v3M14.5 3v3M9.5 18v3M14.5 18v3M3 9.5h3M3 14.5h3M18 9.5h3M18 14.5h3"/>',
    "sparkles": '<path d="M10 3.5c.6 3.6 2.4 5.5 6 6-3.6.6-5.4 2.4-6 6-.6-3.6-2.4-5.4-6-6 3.6-.5 5.4-2.4 6-6Z"/>'
                '<path d="M17.5 14.5c.3 1.7 1.2 2.6 3 3-1.8.3-2.7 1.2-3 3-.3-1.8-1.3-2.7-3-3 1.7-.4 2.7-1.3 3-3Z"/>',
    "wrench": '<path d="M14.7 3.4a5 5 0 0 0-5.9 6.7L3.6 15.3a2 2 0 0 0 0 2.8l2.3 2.3a2 2 0 0 0 2.8 0l5.2-5.2a5 5 0 0 0 6.7-5.9l-3.1 3.1-3.3-.7-.7-3.3Z"/>',
    "notebook": '<rect x="4.5" y="3" width="15" height="18" rx="3"/><path d="M8.5 3v18"/><path d="M12 8h4M12 11.5h4"/>',
    "puzzle": '<path d="M9 4.5a2.2 2.2 0 0 1 4.4 0V6H17a1.5 1.5 0 0 1 1.5 1.5V11h-1.2a2.2 2.2 0 0 0 0 4.4h1.2v3.1A1.5 1.5 0 0 1 17 20H6.5A1.5 1.5 0 0 1 5 18.5V15h1.3a2.2 2.2 0 0 0 0-4.4H5V7.5A1.5 1.5 0 0 1 6.5 6H9Z"/>',
    "plug": '<path d="M9 3.5v4M15 3.5v4"/><path d="M6.5 7.5h11V11a5.5 5.5 0 0 1-11 0Z"/><path d="M12 16.5V21"/>',
    "plane": '<path d="M21 3.5 3.5 10.4l6.7 2.5 2.4 6.8Z"/><path d="M21 3.5 10.2 12.9"/>',
    "wave": '<path d="M4 10.5v3M8 7v10M12 4v16M16 7.5v9M20 10.5v3"/>',
    "branch": '<circle cx="6" cy="5.5" r="2.5"/><circle cx="6" cy="18.5" r="2.5"/><circle cx="18" cy="9" r="2.5"/>'
              '<path d="M6 8v8M18 11.5c0 3.5-2.8 4.5-6 4.5H8.4"/>',
    "key": '<circle cx="7.5" cy="12" r="4"/><path d="M11.5 12H21M17.5 12v3.2M20.5 12v2.2"/>' + dot(7.5, 12, 1.1),
    "bars": '<path d="M4 20h16"/><rect x="5.5" y="11" width="3.4" height="6" rx="1.2"/>'
            '<rect x="10.3" y="5" width="3.4" height="12" rx="1.2"/><rect x="15.1" y="8.5" width="3.4" height="8.5" rx="1.2"/>',
    "terminal": '<rect x="3" y="4" width="18" height="16" rx="3.2"/><path d="M7.5 9.5l3 2.5-3 2.5M12.5 15h4"/>',
    "personCard": '<rect x="3" y="5" width="18" height="14" rx="3"/><circle cx="9" cy="10.6" r="2.2"/>'
                  '<path d="M5.8 16.2c.6-1.6 1.8-2.4 3.2-2.4s2.6.8 3.2 2.4M14.5 10h3.5M14.5 13.5h3.5"/>',
    "tray": '<path d="M3.5 13.5 6 5.8A2 2 0 0 1 7.9 4.5h8.2a2 2 0 0 1 1.9 1.3l2.5 7.7V18a2 2 0 0 1-2 2H5.5a2 2 0 0 1-2-2Z"/>'
            '<path d="M3.5 13.5H8l1.3 2.2h5.4l1.3-2.2h4.5"/>',
    "personCycle": '<circle cx="10" cy="8" r="3.4"/><path d="M4 20c.5-3.4 2.8-5.4 6-5.4 1.2 0 2.3.3 3.2.8"/>'
                   '<path d="M20.5 17.2a3.3 3.3 0 1 1-1-2.4"/><path d="M19.8 13v2h-2"/>',
    "sliders": '<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2.2"/><circle cx="9" cy="17" r="2.2"/>',
    "server": '<rect x="3.5" y="4" width="17" height="7" rx="2.6"/><rect x="3.5" y="13" width="17" height="7" rx="2.6"/>'
              + dot(7.5, 7.5, 1.1) + dot(7.5, 16.5, 1.1) + '<path d="M12 7.5h4.5M12 16.5h4.5"/>',
    "nodes": '<circle cx="12" cy="5.5" r="2.5"/><circle cx="5.5" cy="17.5" r="2.5"/><circle cx="18.5" cy="17.5" r="2.5"/>'
             '<path d="M10.8 7.7 6.7 15.3M13.2 7.7l4.1 7.6M8 17.5h8"/>',
    "shield": '<path d="M12 3 5 5.8v5.6c0 4.4 2.9 7.8 7 9.6 4.1-1.8 7-5.2 7-9.6V5.8Z"/><path d="M9 12l2.1 2.1L15.3 10"/>',
    "palette": '<path d="M12 3.5a8.5 8.5 0 0 0 0 17c1.3 0 1.9-.8 1.9-1.7 0-1.2-1-1.5-1-2.6 0-1 .8-1.7 1.8-1.7h2.2a3.7 3.7 0 0 0 3.6-3.8c0-4.2-3.8-7.2-8.5-7.2Z"/>'
               + dot(8, 10.6, 1.25) + dot(11.2, 7.5, 1.25) + dot(15.3, 8.4, 1.25),
    "tabBar": '<rect x="3" y="4" width="18" height="16" rx="3.2"/><path d="M3 15.5h18"/>' + dot(8, 17.8, 0.95) + dot(12, 17.8, 0.95) + dot(16, 17.8, 0.95),
    "database": '<ellipse cx="12" cy="6" rx="7" ry="2.7"/><path d="M5 6v12c0 1.5 3.1 2.7 7 2.7s7-1.2 7-2.7V6M5 12c0 1.5 3.1 2.7 7 2.7s7-1.2 7-2.7"/>',
    "envelope": '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3.8 7.2 12 13l8.2-5.8"/>',
    "lock": '<rect x="5" y="10.5" width="14" height="10" rx="3"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>' + dot(12, 15.5, 1.4),
    "watch": '<rect x="6" y="6" width="12" height="12" rx="3.6"/><path d="M8.8 6l.6-3h5.2l.6 3M8.8 18l.6 3h5.2l.6-3M12 9.5V12l1.7 1.2"/>',
    "person": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="10" r="3"/><path d="M6.6 18.6c1.2-2 3.1-3 5.4-3s4.2 1 5.4 3"/>',
    "grid3": '<rect x="3.5" y="3.5" width="17" height="7.5" rx="2.4"/><rect x="3.5" y="13" width="7.5" height="7.5" rx="2.4"/><rect x="13" y="13" width="7.5" height="7.5" rx="2.4"/>',
    "face": '<rect x="3.5" y="3.5" width="17" height="17" rx="6"/>' + dot(9.2, 10, 1.25) + dot(14.8, 10, 1.25) + '<path d="M8.8 14.2c.9 1.2 2 1.8 3.2 1.8s2.3-.6 3.2-1.8"/>',
    "chatVoice": bubble(3, 4, 18, 13.2) + '<path d="M8 9.2v3M10.7 8v5.4M13.3 9v3.4M16 9.8v1.8"/>',
    "question": '<circle cx="12" cy="12" r="9"/><path d="M9.6 9.4a2.5 2.5 0 0 1 4.8 1c0 1.7-2.4 2-2.4 3.6"/>' + dot(12, 17, 1.25),
    "paw": '<path d="M12 12.5c-2.8 0-5.3 2.8-5.3 5 0 1.6 1.2 2.5 2.7 2.5 1 0 1.7-.5 2.6-.5s1.6.5 2.6.5c1.5 0 2.7-.9 2.7-2.5 0-2.2-2.5-5-5.3-5Z"/>'
           '<ellipse cx="9" cy="6.6" rx="1.8" ry="2.4"/><ellipse cx="15" cy="6.6" rx="1.8" ry="2.4"/>'
           '<ellipse cx="4.9" cy="10.6" rx="1.6" ry="2"/><ellipse cx="19.1" cy="10.6" rx="1.6" ry="2"/>',
    "gesture": '<path d="M5 15.5c3-6.5 8.2-9.4 14-9"/><path d="M15.8 3.8 19 6.5l-2.8 3.1"/>' + dot(5, 19, 1.8),
}


def svg(inner, size=24):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" '
            f'stroke="#000" stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round">{inner}</svg>\n')


def contact_sheet(names, cols=8, cell=120, pad=24):
    rows = math.ceil(len(names) / cols)
    w, h = cols * cell, rows * (cell + 26)
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">'
             f'<rect width="{w}" height="{h}" fill="#FFF9F5"/>']
    for i, name in enumerate(names):
        x, y = (i % cols) * cell, (i // cols) * (cell + 26)
        s = (cell - 2 * pad) / 24
        parts.append(f'<rect x="{x + 14}" y="{y + 14}" width="{cell - 28}" height="{cell - 28}" rx="{(cell - 28) * 0.26}" fill="#7B52E0" fill-opacity="0.12"/>')
        parts.append(f'<g transform="translate({x + pad} {y + pad}) scale({s})" fill="none" stroke="#6A43CF" '
                     f'stroke-width="{SW}" stroke-linecap="round" stroke-linejoin="round">'
                     + GLYPHS[name].replace('fill="#000"', 'fill="#6A43CF"') + '</g>')
        parts.append(f'<text x="{x + cell / 2}" y="{y + cell + 12}" font-family="Helvetica" font-size="15" '
                     f'text-anchor="middle" fill="#1C1A19">{name}</text>')
    parts.append('</svg>')
    return "\n".join(parts)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, inner in GLYPHS.items():
        with open(os.path.join(OUT, f"{name}.svg"), "w") as f:
            f.write(svg(inner))
    with open(os.path.join(OUT, "_sheet.svg"), "w") as f:
        f.write(contact_sheet(list(GLYPHS)))
    print(len(GLYPHS), "glyphs")
