#!/usr/bin/env python3
"""
bighelp agent avatars: single source of truth.

Generates:
  svg/<id>.svg      standalone animated SVGs (default colorway, idle state)
  avatars.js        ES module: markup, themes, mountAvatar() controller
  themes.json       colorway presets (for native code / design tokens)

Run:  python3 tools/build.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------------------
# Theme presets. Keys map to CSS custom properties on the <svg>:
#   primary -> --av-primary, secondary -> --av-secondary, accent -> --av-accent,
#   background -> --av-bg, ink -> --av-ink, skin -> --av-skin
# "original" sets nothing, so every character keeps its own palette.
# ---------------------------------------------------------------------------
THEMES = {
    "original":  {"name": "Original",  "colors": {}},
    "midnight":  {"name": "Midnight",  "colors": {"primary": "#5A6CFF", "secondary": "#AEB8FF", "accent": "#FFD166", "background": "#1C2045", "ink": "#0F1130"}},
    "neon":      {"name": "Neon",      "colors": {"primary": "#FF3EA5", "secondary": "#7CF7FF", "accent": "#F9F871", "background": "#1A0B2E", "ink": "#13071F"}},
    "sunset":    {"name": "Sunset",    "colors": {"primary": "#FF7A45", "secondary": "#FFC36B", "accent": "#9B5DE5", "background": "#FFE6D6", "ink": "#3A1B2F"}},
    "forest":    {"name": "Forest",    "colors": {"primary": "#3E9B5E", "secondary": "#BCE4AE", "accent": "#F2C14E", "background": "#E4F2E0", "ink": "#1E3326"}},
    "ocean":     {"name": "Ocean",     "colors": {"primary": "#2383E2", "secondary": "#A3D3FF", "accent": "#FFB547", "background": "#E2F1FF", "ink": "#0F2A45"}},
    "royal":     {"name": "Royal",     "colors": {"primary": "#7B52D6", "secondary": "#E3CCFF", "accent": "#FFC53D", "background": "#F2EAFF", "ink": "#25123F"}},
    "bubblegum": {"name": "Bubblegum", "colors": {"primary": "#FF8AB3", "secondary": "#FFDCE9", "accent": "#5FCBFF", "background": "#FFF0F6", "ink": "#3D1F2E"}},
    "mono":      {"name": "Mono",      "colors": {"primary": "#7A7A86", "secondary": "#D8D8DF", "accent": "#FF5A5F", "background": "#EFEFF3", "ink": "#18181C"}},
}

STATES = ["idle", "listening", "thinking", "waiting", "talking", "happy", "sleeping"]

# ---------------------------------------------------------------------------
# Shared rig CSS. Everything is scoped to .bh-avatar so many avatars can live
# inline on one page. Animated parts use view-box pivots (class "pv").
# ---------------------------------------------------------------------------
SHARED_CSS = """
.bh-avatar{overflow:visible;-webkit-tap-highlight-color:transparent}
.bh-avatar *{transform-box:fill-box;transform-origin:center}
.bh-avatar .pv{transform-box:view-box}
.bh-avatar [transform]{transform-box:view-box;transform-origin:0 0}
.bh-avatar .bh-bg{fill:var(--bg)}
.bh-avatar[data-bg="off"] .bh-bg{display:none}
.bh-avatar .bh-shadow{fill:var(--ink);fill-opacity:.14;animation:bh-shadow 3.2s ease-in-out infinite}
.bh-avatar .p{fill:var(--p)}.bh-avatar .s{fill:var(--s)}.bh-avatar .a{fill:var(--a)}
.bh-avatar .k{fill:var(--ink)}.bh-avatar .w{fill:#fff}.bh-avatar .sk{fill:var(--skin)}
.bh-avatar .sh{fill:#000;fill-opacity:.13}.bh-avatar .hl{fill:#fff;fill-opacity:.35}
.bh-avatar .cr{fill:#FFF7EC}.bh-avatar .au{fill:#FFC940}.bh-avatar .pk{fill:#FF7F98}.bh-avatar .hb{fill:#F7F7FC}
.bh-avatar .wg{fill:#FBFCFF;stroke:var(--ink);stroke-opacity:.22;stroke-width:1.4;stroke-linejoin:round}
.bh-avatar .smk{fill:#fff;fill-opacity:.95;stroke:var(--ink);stroke-opacity:.18;stroke-width:1.4}
.bh-avatar .blush{fill:#FF5C8A;fill-opacity:.28}
.bh-avatar .st-p{fill:none;stroke:var(--p);stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-s{fill:none;stroke:var(--s);stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-a{fill:none;stroke:var(--a);stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-k{fill:none;stroke:var(--ink);stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-sk{fill:none;stroke:var(--skin);stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-hb{fill:none;stroke:#F7F7FC;stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .st-sh{fill:none;stroke:#000;stroke-opacity:.13;stroke-linecap:round;stroke-linejoin:round}
.bh-avatar .butt{stroke-linecap:butt}
.bh-avatar .bh-rig{transform-origin:100px 182px;animation:bh-breathe 3.2s ease-in-out infinite}
.bh-avatar .bh-body{transform-origin:100px 182px;transition:transform .45s cubic-bezier(.3,1.3,.5,1)}
.bh-avatar .bh-eye{animation:bh-blink 4.8s infinite}
.bh-avatar .bh-look{translate:calc(var(--lx,0) * var(--look,3px)) calc(var(--ly,0) * var(--look,3px));transition:translate .2s ease-out}
.bh-avatar .bh-talk{transform-origin:50% 0}
.bh-avatar .bh-eyes,.bh-avatar .bh-eyes-happy,.bh-avatar .bh-eyes-sleep,.bh-avatar .bh-smile,.bh-avatar .bh-talk,.bh-avatar .bh-grin,.bh-avatar .bh-fx>g,.bh-avatar .bh-ring{transition:opacity .18s}
.bh-avatar .bh-eyes-happy,.bh-avatar .bh-eyes-sleep,.bh-avatar .bh-talk,.bh-avatar .bh-grin,.bh-avatar .bh-fx>g,.bh-avatar .bh-ring{opacity:0}
.bh-avatar .bh-ring circle{fill:none;stroke:var(--p);stroke-width:3;animation:bh-ring 1.8s ease-out infinite}
.bh-avatar .bh-ring circle+circle{animation-delay:.9s}
.bh-avatar .fxb{fill:#fff;stroke:var(--ink);stroke-opacity:.18;stroke-width:1.5}
.bh-avatar .bh-fx-think{transform-origin:136px 68px;transform:scale(.4);transition:opacity .18s,transform .3s cubic-bezier(.3,1.5,.5,1)}
.bh-avatar .bh-fx-think .d{animation:bh-dot 1.2s ease-in-out infinite}
.bh-avatar .bh-fx-think .d2{animation-delay:.18s}.bh-avatar .bh-fx-think .d3{animation-delay:.36s}
.bh-avatar .bh-fx-zzz text{fill:#fff;stroke:var(--ink);stroke-width:2.4;paint-order:stroke;font-family:ui-rounded,"SF Pro Rounded",system-ui,-apple-system,"Segoe UI",sans-serif;font-weight:800;animation:bh-z 2.7s ease-in-out infinite}
.bh-avatar .bh-fx-zzz text:nth-child(2){animation-delay:.9s}.bh-avatar .bh-fx-zzz text:nth-child(3){animation-delay:1.8s}
.bh-avatar .bh-fx-sparkle path{fill:var(--a);stroke:var(--ink);stroke-opacity:.25;stroke-width:1.2;animation:bh-twinkle 1.6s ease-in-out infinite}
.bh-avatar .bh-fx-sparkle path:nth-child(2){animation-delay:.4s}.bh-avatar .bh-fx-sparkle path:nth-child(3){animation-delay:.8s}.bh-avatar .bh-fx-sparkle path:nth-child(4){animation-delay:1.2s}
/* listening */
.bh-avatar[data-state="listening"] .bh-body{transform:rotate(5deg)}
.bh-avatar[data-state="listening"] .bh-ring{opacity:1}
/* thinking */
.bh-avatar[data-state="thinking"] .bh-body{transform:rotate(-4deg)}
.bh-avatar[data-state="thinking"] .bh-look{translate:calc(var(--look,3px) * .7) calc(var(--look,3px) * -1)}
.bh-avatar[data-state="thinking"] .bh-fx-think{opacity:1;transform:scale(1)}
/* talking */
.bh-avatar[data-state="talking"] .bh-smile{opacity:0}
.bh-avatar[data-state="talking"] .bh-talk{opacity:1;animation:bh-talk .3s ease-in-out infinite alternate}
.bh-avatar[data-state="talking"] .bh-rig{animation:bh-chatter .6s ease-in-out infinite alternate}
/* happy */
.bh-avatar[data-state="happy"] .bh-eyes,.bh-avatar[data-state="happy"] .bh-smile{opacity:0}
.bh-avatar[data-state="happy"] .bh-eyes-happy,.bh-avatar[data-state="happy"] .bh-grin,.bh-avatar[data-state="happy"] .bh-fx-sparkle{opacity:1}
.bh-avatar[data-state="happy"] .bh-rig{animation:bh-hop .8s cubic-bezier(.35,0,.4,1) infinite}
.bh-avatar[data-state="happy"] .bh-shadow{animation:bh-hop-shadow .8s cubic-bezier(.35,0,.4,1) infinite}
/* sleeping */
.bh-avatar[data-state="sleeping"] .bh-eyes{opacity:0}
.bh-avatar[data-state="sleeping"] .bh-eyes-sleep,.bh-avatar[data-state="sleeping"] .bh-fx-zzz{opacity:1}
.bh-avatar[data-state="sleeping"] .bh-rig{animation:bh-breathe 5s ease-in-out infinite}
.bh-avatar[data-state="sleeping"] .bh-body{transform:rotate(-3deg)}
.bh-avatar[data-state="sleeping"] .anim{animation:none}
/* waiting: blocked on the user */
.bh-avatar[data-state="waiting"] .bh-look{animation:bh-scan 2.6s ease-in-out infinite}
.bh-avatar[data-state="waiting"] .bh-body{animation:bh-sway 2.6s ease-in-out infinite}
.bh-avatar[data-state="waiting"] .bh-fx-wait{opacity:1}
.bh-avatar .fxw{fill:var(--a);stroke:var(--ink);stroke-opacity:.3;stroke-width:1.5}
.bh-avatar .bh-fx-wait .badge{animation:bh-pulse 1.3s ease-in-out infinite}
/* tap reaction (JS adds .bh-poke) */
.bh-avatar.bh-poke .bh-body{animation:bh-squish .55s cubic-bezier(.3,1.5,.5,1)}
@keyframes bh-breathe{0%,100%{transform:translateY(0)}50%{transform:translateY(-3px)}}
@keyframes bh-shadow{0%,100%{transform:scaleX(1)}50%{transform:scaleX(.92)}}
@keyframes bh-blink{0%,93%,100%{transform:scaleY(1)}96%{transform:scaleY(.1)}}
@keyframes bh-talk{0%{transform:scaleY(.3)}100%{transform:scaleY(1)}}
@keyframes bh-chatter{0%{transform:translateY(0) rotate(-1deg)}100%{transform:translateY(-2px) rotate(1deg)}}
@keyframes bh-hop{0%,100%{transform:translateY(0) scale(1.04,.96)}45%{transform:translateY(-9px) scale(.98,1.02)}}
@keyframes bh-hop-shadow{0%,100%{transform:scaleX(1.05)}45%{transform:scaleX(.78)}}
@keyframes bh-ring{0%{transform:scale(.9);opacity:.75}100%{transform:scale(1.04);opacity:0}}
@keyframes bh-dot{0%,60%,100%{transform:translateY(0);opacity:.45}30%{transform:translateY(-3px);opacity:1}}
@keyframes bh-z{0%{opacity:0;transform:translate(0,4px) scale(.6)}30%{opacity:1}100%{opacity:0;transform:translate(7px,-12px) scale(1.1)}}
@keyframes bh-twinkle{0%,100%{transform:scale(.2) rotate(0);opacity:0}50%{transform:scale(1) rotate(45deg);opacity:1}}
@keyframes bh-scan{0%,100%{translate:calc(var(--look,3px) * -1) 0}50%{translate:var(--look,3px) 0}}
@keyframes bh-sway{0%,100%{transform:rotate(-3deg)}50%{transform:rotate(3deg)}}
@keyframes bh-pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.12)}}
@keyframes bh-squish{0%{transform:scale(1,1)}25%{transform:scale(1.1,.88)}55%{transform:scale(.95,1.06)}100%{transform:scale(1,1)}}
@media (prefers-reduced-motion:reduce){.bh-avatar *{animation:none!important;transition:none!important}}
"""


# ---------------------------------------------------------------------------
# Drawing helpers
# ---------------------------------------------------------------------------
def n(x):
    return ("%.2f" % x).rstrip("0").rstrip(".")


def mirror(markup):
    """Reflect a fragment across x=100 (CSS animations inside stay symmetric)."""
    return '<g transform="matrix(-1 0 0 1 200 0)">%s</g>' % markup


def sell(cls, cx, cy, rx, ry, k=4, dx=-2.5, dy=-3.5):
    """Ellipse with a soft bottom-right shade crescent that follows the theme."""
    return ('<ellipse class="%s" cx="%s" cy="%s" rx="%s" ry="%s"/>'
            '<ellipse class="sh" cx="%s" cy="%s" rx="%s" ry="%s"/>'
            '<ellipse class="%s" cx="%s" cy="%s" rx="%s" ry="%s"/>') % (
        cls, n(cx), n(cy), n(rx), n(ry),
        n(cx), n(cy), n(rx), n(ry),
        cls, n(cx + dx), n(cy + dy), n(rx - k), n(ry - k))


def srect(cls, x, y, w, h, r, k=4):
    return ('<rect class="%s" x="%s" y="%s" width="%s" height="%s" rx="%s"/>'
            '<rect class="sh" x="%s" y="%s" width="%s" height="%s" rx="%s"/>'
            '<rect class="%s" x="%s" y="%s" width="%s" height="%s" rx="%s"/>') % (
        cls, n(x), n(y), n(w), n(h), n(r),
        n(x), n(y), n(w), n(h), n(r),
        cls, n(x), n(y), n(w - k), n(h - k), n(r - 1))


def eye(cx, cy, rx, ry, pr, iris=None, iris_r=None, slit=False, extra=""):
    look = ""
    if iris:
        look += '<circle class="%s" cx="%s" cy="%s" r="%s"/>' % (iris, n(cx), n(cy), n(iris_r))
    if slit:
        look += '<ellipse class="k" cx="%s" cy="%s" rx="%s" ry="%s"/>' % (n(cx), n(cy), n(pr * 0.4), n(pr))
    else:
        look += '<circle class="k" cx="%s" cy="%s" r="%s"/>' % (n(cx), n(cy), n(pr))
    g = (iris_r or pr) * 0.36
    look += '<circle class="w" cx="%s" cy="%s" r="%s"/>' % (n(cx + g * 0.95), n(cy - g * 0.95), n(g))
    look += '<circle class="w" cx="%s" cy="%s" r="%s" opacity=".7"/>' % (n(cx - g * 0.9), n(cy + g * 1.1), n(g * 0.45))
    return ('<g class="bh-eye"><ellipse class="w" cx="%s" cy="%s" rx="%s" ry="%s"/>'
            '<g class="bh-look">%s</g>%s</g>') % (n(cx), n(cy), n(rx), n(ry), look, extra)


def eye_states(pts, w, h, cls="st-k", sw=3.6):
    happy = "".join('<path class="%s" stroke-width="%s" d="M%s %s Q%s %s %s %s"/>' % (
        cls, n(sw), n(x - w), n(y + h * 0.35), n(x), n(y - h), n(x + w), n(y + h * 0.35)) for x, y in pts)
    sleep = "".join('<path class="%s" stroke-width="%s" d="M%s %s Q%s %s %s %s"/>' % (
        cls, n(sw), n(x - w), n(y), n(x), n(y + h * 0.7), n(x + w), n(y)) for x, y in pts)
    return '<g class="bh-eyes-happy">%s</g><g class="bh-eyes-sleep">%s</g>' % (happy, sleep)


def mouth(cx, cy, w, smile=None, talk=None, grin=None, sw=3.2):
    if smile is None:
        smile = '<path class="st-k" stroke-width="%s" d="M%s %s Q%s %s %s %s"/>' % (
            n(sw), n(cx - w / 2), n(cy), n(cx), n(cy + w * 0.5), n(cx + w / 2), n(cy))
    if talk is None:
        talk = ('<ellipse class="k" cx="%s" cy="%s" rx="%s" ry="%s"/>'
                '<ellipse class="pk" cx="%s" cy="%s" rx="%s" ry="%s"/>') % (
            n(cx), n(cy + w * 0.3), n(w * 0.32), n(w * 0.32),
            n(cx), n(cy + w * 0.46), n(w * 0.18), n(w * 0.1))
    if grin is None:
        grin = ('<path class="k" d="M%s %s Q%s %s %s %s Z"/>'
                '<ellipse class="pk" cx="%s" cy="%s" rx="%s" ry="%s"/>') % (
            n(cx - w * 0.6), n(cy - 1), n(cx), n(cy + w * 0.98), n(cx + w * 0.6), n(cy - 1),
            n(cx), n(cy + w * 0.33), n(w * 0.22), n(w * 0.1))
    return ('<g class="bh-mouth"><g class="bh-smile">%s</g><g class="bh-talk">%s</g>'
            '<g class="bh-grin">%s</g></g>') % (smile, talk, grin)


def blush(pts, rx=6.5, ry=4):
    return '<g class="bh-blush">%s</g>' % "".join(
        '<ellipse class="blush" cx="%s" cy="%s" rx="%s" ry="%s"/>' % (n(x), n(y), n(rx), n(ry)) for x, y in pts)


def star(cx, cy, r):
    return ('M{x} {t} Q{x} {y} {r_} {y} Q{x} {y} {x} {b} Q{x} {y} {l} {y} Q{x} {y} {x} {t} Z'
            .format(x=n(cx), y=n(cy), t=n(cy - r), b=n(cy + r), l=n(cx - r), r_=n(cx + r)))


FX = (
    '<g class="bh-fx">'
    '<g class="bh-fx-think pv">'
    '<circle class="fxb" cx="137" cy="66" r="3.4"/><circle class="fxb" cx="145" cy="56" r="4.8"/>'
    '<ellipse class="fxb" cx="158" cy="41" rx="18" ry="12.5"/>'
    '<circle class="k d d1" cx="151" cy="41" r="2.5"/><circle class="k d d2" cx="158" cy="41" r="2.5"/>'
    '<circle class="k d d3" cx="165" cy="41" r="2.5"/></g>'
    '<g class="bh-fx-zzz"><text x="140" y="62" font-size="18">Z</text>'
    '<text x="153" y="46" font-size="14">z</text><text x="163" y="33" font-size="11">z</text></g>'
    '<g class="bh-fx-wait"><g class="badge"><circle class="fxw" cx="158" cy="42" r="13"/>'
    '<rect class="k" x="156" y="33" width="4" height="11.5" rx="2"/><circle class="k" cx="158" cy="49" r="2.3"/></g></g>'
    '<g class="bh-fx-sparkle">'
    '<path d="%s"/><path d="%s"/><path d="%s"/><path d="%s"/></g>'
    '</g>'
) % (star(36, 50, 8), star(166, 58, 7), star(162, 146, 6), star(34, 138, 5.5))


# ---------------------------------------------------------------------------
# Characters. Each returns (back, body, front) markup plus CSS.
#   back  : drawn behind the rigged body (still inside the rig)
#   body  : the character itself
# All parts live inside .bh-rig > .bh-body so states move everything together.
# ---------------------------------------------------------------------------
CHARACTERS = []


def character(cid, name, role, colors, css):
    def deco(fn):
        CHARACTERS.append({"id": cid, "name": name, "role": role, "colors": colors, "css": css, "draw": fn})
        return fn
    return deco


# 1. Lobster ---------------------------------------------------------------
@character("lobster", "Pinch", "Lobster",
           {"p": "#E8553E", "s": "#FFC3A9", "a": "#FFD166", "bg": "#FFEAE3"},
           """
.bh-av--lobster .lob-ant-l{transform-origin:91px 76px;animation:lob-ant 3.4s ease-in-out infinite}
.bh-av--lobster .lob-ant-r{transform-origin:109px 76px;animation:lob-ant 3.4s ease-in-out infinite reverse}
.bh-av--lobster .lob-claw{transform-origin:68px 118px;animation:lob-wave 3.2s ease-in-out infinite}
.bh-av--lobster .lob-pinch{transform-origin:52px 82px;animation:lob-pinch 4.2s ease-in-out infinite}
.bh-av--lobster[data-state="talking"] .lob-claw{animation-duration:1.2s}
.bh-av--lobster[data-state="happy"] .lob-pinch{animation:lob-snap .4s ease-in-out infinite alternate}
.bh-av--lobster[data-state="happy"] .lob-claw{animation:lob-cheer .8s ease-in-out infinite}
@keyframes lob-ant{0%,100%{transform:rotate(-6deg)}50%{transform:rotate(5deg)}}
@keyframes lob-wave{0%,100%{transform:rotate(0)}50%{transform:rotate(-7deg)}}
@keyframes lob-pinch{0%,62%,100%{transform:rotate(0)}68%,72%{transform:rotate(-20deg)}78%{transform:rotate(0)}84%{transform:rotate(-20deg)}90%{transform:rotate(0)}}
@keyframes lob-snap{to{transform:rotate(-20deg)}}
@keyframes lob-cheer{0%,100%{transform:rotate(0)}45%{transform:rotate(12deg)}}
""")
def draw_lobster():
    ant = ('<g class="pv anim lob-ant-l"><path class="st-p" stroke-width="4" d="M91 76 C 85 46, 72 30, 48 24"/>'
           '<circle class="a" cx="48" cy="24" r="4.5"/></g>'
           '<g class="pv anim lob-ant-r"><path class="st-p" stroke-width="4" d="M109 76 C 115 46, 128 30, 152 24"/>'
           '<circle class="a" cx="152" cy="24" r="4.5"/></g>')
    leg = ('<path class="st-p" stroke-width="6" d="M70 140 L55 150"/>'
           '<path class="st-p" stroke-width="6" d="M72 151 L59 163"/>')
    tail = ('<ellipse class="p" cx="85" cy="167" rx="11" ry="9"/><ellipse class="sh" cx="85" cy="167" rx="11" ry="9"/>'
            '<ellipse class="p" cx="115" cy="167" rx="11" ry="9"/><ellipse class="sh" cx="115" cy="167" rx="11" ry="9"/>'
            '<ellipse class="p" cx="100" cy="171" rx="12" ry="9"/>')
    claw = ('<g class="pv anim lob-claw">'
            '<path class="st-p" stroke-width="12" d="M68 118 Q 52 112 46 96"/>'
            '<g class="pv anim lob-pinch"><path class="p" d="M42 80 C 46 66, 50 56, 54 44 C 64 56, 66 72, 58 84 Z"/></g>'
            '<path class="p" d="M26 86 C 18 68, 20 52, 32 40 C 36 52, 40 64, 46 78 Z"/>'
            + sell("p", 42, 88, 18, 14, k=3.5) +
            '<ellipse class="hl" cx="35" cy="83" rx="5" ry="3" transform="rotate(-25 35 83)"/>'
            '</g>')
    stalks = ('<path class="st-p" stroke-width="8" d="M89 78 L84 62"/><path class="st-p" stroke-width="8" d="M111 78 L116 62"/>'
              '<circle class="p" cx="82" cy="54" r="13.5"/><circle class="p" cx="118" cy="54" r="13.5"/>')
    belly = ('<ellipse class="s" cx="100" cy="134" rx="25" ry="22"/>'
             '<path class="st-sh" stroke-width="2.4" d="M80 126 Q100 132 120 126"/>'
             '<path class="st-sh" stroke-width="2.4" d="M78 138 Q100 144 122 138"/>'
             '<path class="st-sh" stroke-width="2.4" d="M82 149 Q100 154 118 149"/>')
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(82, 54, 10.5, 11.5, 6.4), eye(118, 54, 10.5, 11.5, 6.4))
    return (ant + leg + mirror(leg) + tail + claw + mirror(claw)
            + sell("p", 100, 116, 40, 46)
            + '<ellipse class="hl" cx="80" cy="86" rx="9" ry="5" transform="rotate(-35 80 86)"/>'
            + belly + stalks + eyes + eye_states([(82, 54), (118, 54)], 7, 6)
            + mouth(100, 97, 16) + blush([(76, 101), (124, 101)]))


# 2. Winged messenger (original character) ----------------------------------
@character("messenger", "Aeria", "Winged messenger",
           {"p": "#5B6CFF", "s": "#3B2B55", "a": "#FFC94A", "bg": "#E8EBFF", "skin": "#F7D0B5"},
           """
.bh-av--messenger{--look:2px}
.bh-av--messenger .msg-wing{transform-origin:62px 74px;animation:msg-flap 3.6s ease-in-out infinite}
.bh-av--messenger .msg-lock{transform-origin:66px 90px;animation:msg-sway 3.2s ease-in-out infinite}
.bh-av--messenger[data-state="happy"] .msg-wing{animation:msg-flutter .3s ease-in-out infinite alternate}
.bh-av--messenger[data-state="talking"] .msg-wing{animation-duration:1.6s}
@keyframes msg-flap{0%,58%,100%{transform:rotate(0)}64%{transform:rotate(-14deg)}70%{transform:rotate(2deg)}76%{transform:rotate(-14deg)}82%{transform:rotate(0)}}
@keyframes msg-sway{0%,100%{transform:rotate(-2deg)}50%{transform:rotate(3deg)}}
@keyframes msg-flutter{from{transform:rotate(2deg)}to{transform:rotate(-16deg)}}
""")
def draw_messenger():
    lock = '<g class="pv anim msg-lock"><path class="s" d="M58 86 C 50 112, 50 136, 62 158 C 70 146, 76 126, 76 100 Z"/></g>'
    wing = ('<g class="pv anim msg-wing">'
            '<path class="wg" d="M60 77 C 48 78, 36 74, 30 64 C 42 66, 52 68, 62 72 Z"/>'
            '<path class="wg" d="M60 74 C 46 70, 34 62, 28 48 C 42 52, 54 58, 64 68 Z"/>'
            '<path class="wg" d="M62 72 C 50 64, 40 50, 38 34 C 50 42, 60 52, 67 64 Z"/>'
            '</g>')
    body = ('<path class="p" d="M56 180 C 56 158, 74 146, 100 146 C 126 146, 144 158, 144 180 Q 100 188 56 180 Z"/>'
            '<path class="sh" d="M128 152 C 138 158, 144 168, 144 180 Q 136 182 126 183 C 130 172, 130 160, 128 152 Z"/>'
            '<ellipse class="hl" cx="72" cy="160" rx="8" ry="4" transform="rotate(-25 72 160)"/>'
            '<rect class="sk" x="91" y="122" width="18" height="28" rx="6"/>'
            '<rect class="sh" x="91" y="124" width="18" height="10" rx="3"/>'
            '<path class="sk" d="M88 147 Q 100 145 112 147 L 100 162 Z"/>'
            '<path class="st-a" stroke-width="3" d="M86 147 L100 163 L114 147"/>'
            '<path class="st-a" stroke-width="6" d="M70 152 L 130 178"/>'
            '<rect class="au" x="95.5" y="160" width="10" height="9" rx="2" transform="rotate(23 100.5 164.5)"/>')
    eyes = ('<g class="bh-eyes">%s%s</g>' % (
        eye(85, 99, 9, 10.5, 3.8, iris="p", iris_r=7,
            extra='<path class="st-k" stroke-width="2.6" d="M75.5 96 Q 84 86 94.5 93"/><path class="st-k" stroke-width="2.2" d="M76.5 95 L72.5 92"/>'),
        eye(115, 99, 9, 10.5, 3.8, iris="p", iris_r=7,
            extra='<path class="st-k" stroke-width="2.6" d="M105.5 93 Q 116 86 124.5 96"/><path class="st-k" stroke-width="2.2" d="M123.5 95 L127.5 92"/>')))
    head = ('<ellipse class="sk" cx="63" cy="97" rx="6" ry="8"/><ellipse class="sk" cx="137" cy="97" rx="6" ry="8"/>'
            '<circle class="sk" cx="100" cy="90" r="38"/>'
            '<path class="st-s" stroke-width="2.6" d="M78 85 Q85 81 92 84"/><path class="st-s" stroke-width="2.6" d="M108 84 Q115 81 122 85"/>'
            + eyes + eye_states([(85, 99), (115, 99)], 7, 6, sw=3.2)
            + '<ellipse class="sh" cx="100" cy="107.5" rx="2.2" ry="1.6"/>'
            + mouth(100, 115, 11, sw=2.8) + blush([(75, 110), (125, 110)], 6, 3.6))
    bangs = '<path class="s" d="M62 90 C 60 64, 76 50, 100 50 C 124 50, 140 64, 138 90 C 133 80, 126 74, 118 74 C 112 70, 106 72, 101 80 C 96 72, 88 70, 80 75 C 72 74, 65 80, 62 90 Z"/>'
    cap = ('<path class="p" d="M60 76 C 60 50, 78 36, 100 36 C 122 36, 140 50, 140 76 Z"/>'
           '<path class="sh" d="M122 42 C 134 50, 140 62, 140 76 L 128 74 C 130 62, 128 50, 122 42 Z"/>'
           '<path class="a" d="M56 78 C 72 66, 128 66, 144 78 C 146 82, 143 85, 139 84 C 124 75, 76 75, 61 84 C 57 85, 54 82, 56 78 Z"/>'
           '<ellipse class="hl" cx="84" cy="50" rx="11" ry="5" transform="rotate(-20 84 50)"/>')
    return ('<ellipse class="s" cx="100" cy="88" rx="46" ry="46"/>'
            + body + lock + mirror(lock) + head + bangs + cap + wing + mirror(wing))


# 3. Dog -------------------------------------------------------------------
@character("dog", "Biscuit", "Dog",
           {"p": "#E5A45F", "s": "#8C5A3B", "a": "#E5484D", "bg": "#FFF1DF"},
           """
.bh-av--dog{--look:2.5px}
.bh-av--dog .dog-tail{transform-origin:130px 168px;animation:dog-wag 1.2s ease-in-out infinite alternate}
.bh-av--dog .dog-ear{transform-origin:70px 60px;animation:dog-ear 3.2s ease-in-out infinite}
.bh-av--dog .dog-tag{transform-origin:100px 149px;animation:dog-tag 2.4s ease-in-out infinite}
.bh-av--dog[data-state="happy"] .dog-tail{animation-duration:.18s}
.bh-av--dog[data-state="talking"] .dog-tail{animation-duration:.5s}
.bh-av--dog[data-state="happy"] .dog-ear{animation:dog-flop .4s ease-in-out infinite alternate}
.bh-av--dog[data-state="listening"] .dog-ear{animation:none;transform:rotate(14deg)}
@keyframes dog-wag{from{transform:rotate(-8deg)}to{transform:rotate(12deg)}}
@keyframes dog-ear{0%,100%{transform:rotate(0)}50%{transform:rotate(5deg)}}
@keyframes dog-flop{from{transform:rotate(-4deg)}to{transform:rotate(10deg)}}
@keyframes dog-tag{0%,100%{transform:rotate(-8deg)}50%{transform:rotate(8deg)}}
""")
def draw_dog():
    tail = '<g class="pv anim dog-tail"><path class="p" d="M128 164 C 146 160, 156 146, 158 130 C 163 134, 165 142, 161 152 C 155 164, 142 170, 130 170 Z"/></g>'
    paws = ('<ellipse class="p" cx="84" cy="178" rx="11" ry="7"/><ellipse class="p" cx="116" cy="178" rx="11" ry="7"/>'
            '<path class="st-sh" stroke-width="1.8" d="M80 175 L80 181 M88 175 L88 181 M112 175 L112 181 M120 175 L120 181"/>')
    body = ('<path class="p" d="M64 180 C 60 152, 76 132, 100 132 C 124 132, 140 152, 136 180 Q 100 188 64 180 Z"/>'
            '<ellipse class="cr" cx="100" cy="162" rx="17" ry="16"/>' + paws +
            '<path class="a" d="M70 134 Q 100 150 130 134 L 130 142 Q 100 158 70 142 Z"/>'
            '<g class="pv anim dog-tag"><circle class="au" cx="100" cy="155" r="6"/><circle class="sh" cx="100" cy="155" r="2"/></g>')
    ear = '<g class="pv anim dog-ear"><path class="s" d="M68 58 C 52 56, 40 72, 42 98 C 44 116, 54 122, 62 116 C 70 108, 74 86, 78 66 Z"/></g>'
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(85, 90, 8.5, 9.5, 5.8), eye(115, 90, 8.5, 9.5, 5.8))
    face = ('<ellipse class="s" cx="85" cy="88" rx="14" ry="13" transform="rotate(-15 85 88)"/>'
            '<ellipse class="hl" cx="86" cy="63" rx="12" ry="5"/>'
            '<ellipse class="cr" cx="100" cy="116" rx="24" ry="17"/>'
            + eyes + eye_states([(85, 90), (115, 90)], 6.5, 5.5)
            + mouth(100, 118, 18,
                    smile='<path class="st-k" stroke-width="2.8" d="M100 112 L100 119 M90 118 Q95 124 100 119 Q105 124 110 118"/>',
                    talk='<ellipse class="k" cx="100" cy="124" rx="7" ry="6.5"/><ellipse class="pk" cx="100" cy="127.5" rx="4" ry="2.2"/>',
                    grin='<path class="k" d="M88 117 Q100 136 112 117 Z"/><path class="pk" d="M94 124 Q100 122 106 124 L106 132 Q100 138 94 132 Z"/>')
            + '<path class="k" d="M91 104 Q100 99 109 104 Q108 112 100 113 Q92 112 91 104 Z"/>'
            '<ellipse class="w" cx="96" cy="103.5" rx="3" ry="1.6" opacity=".6"/>'
            + blush([(71, 111), (129, 111)]))
    return tail + body + sell("p", 100, 94, 46, 42) + face + ear + mirror(ear)


# 4. Cat -------------------------------------------------------------------
@character("cat", "Miso", "Cat",
           {"p": "#F29A4A", "s": "#FFE3C8", "a": "#3FBFA0", "bg": "#FFF0E2"},
           """
.bh-av--cat{--look:2.5px}
.bh-av--cat .cat-tail{transform-origin:126px 172px;animation:cat-swish 2.6s ease-in-out infinite alternate}
.bh-av--cat .cat-ear{transform-origin:76px 66px;animation:cat-twitch 5s ease-in-out infinite}
.bh-av--cat .cat-ear-r{animation-delay:-2.6s}
.bh-av--cat[data-state="happy"] .cat-tail{animation-duration:.6s}
.bh-av--cat[data-state="listening"] .cat-ear{animation:none;transform:rotate(6deg)}
@keyframes cat-swish{from{transform:rotate(-8deg)}to{transform:rotate(8deg)}}
@keyframes cat-twitch{0%,86%,100%{transform:rotate(0)}89%{transform:rotate(-10deg)}92%{transform:rotate(0)}}
""")
def draw_cat():
    tail = ('<g class="pv anim cat-tail"><path class="st-p" stroke-width="12" d="M126 172 C 154 172, 166 148, 158 126 C 154 114, 160 104, 170 106"/>'
            '<path class="st-sh" stroke-width="12" d="M158 126 C 154 114, 160 104, 170 106"/></g>')
    body = ('<path class="p" d="M66 180 C 62 156, 78 140, 100 140 C 122 140, 138 156, 134 180 Q 100 187 66 180 Z"/>'
            '<ellipse class="s" cx="100" cy="166" rx="15" ry="14"/>'
            '<ellipse class="s" cx="87" cy="179" rx="9" ry="6"/><ellipse class="s" cx="113" cy="179" rx="9" ry="6"/>'
            '<path class="a" d="M74 140 Q100 152 126 140 L126 147 Q100 159 74 147 Z"/>'
            '<circle class="au" cx="100" cy="158" r="5"/><path class="st-sh" stroke-width="1.5" d="M96 159 L104 159"/>')
    ear = ('<g class="pv anim cat-ear"><path class="p" d="M56 82 L 60 40 Q 62 32 69 37 L 94 58 Z"/>'
           '<path class="s" d="M63 72 L 65 47 L 84 60 Z"/></g>')
    eyes = '<g class="bh-eyes">%s%s</g>' % (
        eye(80, 93, 10.5, 10, 6.4, iris="a", iris_r=7.5, slit=True),
        eye(120, 93, 10.5, 10, 6.4, iris="a", iris_r=7.5, slit=True))
    stripes = ('<path class="st-sh" stroke-width="4.5" d="M93 61 L95 71 M100 59 L100 73 M107 61 L105 71 '
               'M53 98 L64 100 M54 107 L63 106 M147 98 L136 100 M146 107 L137 106"/>')
    face = (stripes
            + '<ellipse class="s" cx="91" cy="116" rx="11" ry="9"/><ellipse class="s" cx="109" cy="116" rx="11" ry="9"/>'
            '<ellipse class="s" cx="100" cy="124" rx="8" ry="5"/>'
            + eyes + eye_states([(80, 93), (120, 93)], 7.5, 6)
            + mouth(100, 117, 14,
                    smile='<path class="st-k" stroke-width="2.4" d="M100 113 L100 117 M92 117 Q96 121 100 117 Q104 121 108 117"/>',
                    talk='<ellipse class="k" cx="100" cy="121" rx="5.5" ry="5"/><ellipse class="pk" cx="100" cy="123.5" rx="3" ry="1.6"/>',
                    grin='<path class="k" d="M91 116 Q100 131 109 116 Z"/><ellipse class="pk" cx="100" cy="121.5" rx="3.6" ry="1.8"/>')
            + '<path class="pk" d="M95 108 Q100 106 105 108 Q103 113 100 114 Q97 113 95 108 Z"/>'
            '<g class="st-k" stroke-width="1.6" opacity=".55"><path d="M72 114 L50 110"/><path d="M72 119 L50 121"/>'
            '<path d="M128 114 L150 110"/><path d="M128 119 L150 121"/></g>'
            + blush([(70, 107), (130, 107)]))
    return (tail + body + ear + mirror(ear.replace("cat-ear", "cat-ear cat-ear-r"))
            + sell("p", 100, 98, 48, 40) + face)


# 5. Zeus-like sky king ------------------------------------------------------
@character("zeus", "Bolt", "Sky king",
           {"p": "#3D5AFE", "s": "#EEF0F9", "a": "#FFC53D", "bg": "#E3E8FF", "skin": "#F1C4A0"},
           """
.bh-av--zeus{--look:2px}
.bh-av--zeus .zeus-arm{transform-origin:66px 158px;animation:zeus-hold 3.4s ease-in-out infinite}
.bh-av--zeus .zeus-glow{animation:zeus-glow 1.8s ease-in-out infinite}
.bh-av--zeus .zeus-spark{opacity:0;animation:zeus-spark 1.1s ease-in-out infinite}
.bh-av--zeus .zeus-spark+.zeus-spark{animation-delay:-.55s}
.bh-av--zeus[data-state="talking"] .zeus-brow{animation:zeus-brow .6s ease-in-out infinite alternate}
.bh-av--zeus[data-state="happy"] .zeus-arm{animation:zeus-raise .8s ease-in-out infinite}
.bh-av--zeus[data-state="happy"] .zeus-spark,.bh-av--zeus[data-state="talking"] .zeus-spark{animation-duration:.4s}
@keyframes zeus-hold{0%,100%{transform:rotate(-3deg)}50%{transform:rotate(3deg)}}
@keyframes zeus-glow{0%,100%{opacity:.25}50%{opacity:.65}}
@keyframes zeus-spark{0%,100%{opacity:0}40%,60%{opacity:1}}
@keyframes zeus-brow{to{transform:translateY(-2.5px)}}
@keyframes zeus-raise{0%,100%{transform:rotate(0)}45%{transform:rotate(8deg) translateY(-5px)}}
""")
def draw_zeus():
    cloud = [(58, 94), (58, 70), (70, 50), (88, 40), (112, 40), (130, 50), (142, 70), (142, 94)]
    hair = ('<ellipse class="sh" cx="100" cy="86" rx="47.5" ry="45.5"/>'
            + "".join('<circle class="sh" cx="%d" cy="%d" r="15.5"/>' % c for c in cloud)
            + '<ellipse class="hb" cx="100" cy="86" rx="46" ry="44"/>'
            + "".join('<circle class="hb" cx="%d" cy="%d" r="14"/>' % c for c in cloud))
    bolt = "M46 36 L28 80 L42 80 L30 124 L60 70 L46 70 L58 36 Z"
    arm = ('<g class="pv anim zeus-arm">'
           '<path class="a zeus-glow" style="stroke:var(--a);stroke-width:9;stroke-linejoin:round" d="%s"/>'
           '<path class="a" style="stroke:var(--ink);stroke-opacity:.22;stroke-width:1.5;stroke-linejoin:round" d="%s"/>'
           '<path class="hl" d="M50 42 L38 72 L44 72 L54 42 Z"/>'
           '<path class="st-a zeus-spark" stroke-width="2.6" d="M22 52 L15 48 M66 50 L73 45 M20 92 L13 94"/>'
           '<path class="st-a zeus-spark" stroke-width="2.6" d="M24 68 L17 70 M64 64 L71 66 M26 118 L20 124"/>'
           '<path class="st-sk" stroke-width="14" d="M66 158 Q 50 140 44 112"/>'
           '<path class="st-a butt" stroke-width="15" d="M48.3 128 L45.8 120"/>'
           '<circle class="sk" cx="44" cy="106" r="10"/>'
           '<path class="st-sh" stroke-width="2" d="M36 103 L50 103 M36 108 L50 108"/>'
           '</g>') % (bolt, bolt)
    body = ('<path class="s" d="M52 180 C 52 158, 72 146, 100 146 C 128 146, 148 158, 148 180 Q 100 188 52 180 Z"/>'
            '<path class="st-sh" stroke-width="2.4" d="M112 162 Q 118 172 116 183 M128 158 Q 136 168 134 181"/>'
            '<path class="p" d="M66 151 Q 74 146 84 146 L 146 172 Q 147 178 144 182 L 128 184 Z"/>'
            '<path class="st-a" stroke-width="2.4" d="M84 146 L 146 172"/>'
            '<circle class="a" cx="76" cy="151" r="5.5"/><circle class="sh" cx="76" cy="151" r="2"/>'
            '<rect class="sk" x="90" y="124" width="20" height="26" rx="6"/>')
    beard = "M66 96 C 63 128, 78 160, 100 166 C 122 160, 137 128, 134 96 C 131 110, 124 118, 116 121 C 110 117, 90 117, 84 121 C 76 118, 69 110, 66 96 Z"
    stache = "M100 112 C 94 105, 82 105, 77 113 C 85 115, 93 117, 100 116 C 107 117, 115 115, 123 113 C 118 105, 106 105, 100 112 Z"
    leaves = []
    for i, t in enumerate([0.06, 0.18, 0.3, 0.42, 0.58, 0.7, 0.82, 0.94]):
        x = (1 - t) ** 2 * 64 + 2 * (1 - t) * t * 100 + t ** 2 * 136
        y = (1 - t) ** 2 * 76 + 2 * (1 - t) * t * 46 + t ** 2 * 76
        tx, ty = 2 * (1 - t) * (100 - 64) + 2 * t * (136 - 100), 2 * (1 - t) * (46 - 76) + 2 * t * (76 - 46)
        import math
        ang = math.degrees(math.atan2(ty, tx)) + (-38 if i % 2 == 0 else 38)
        leaves.append('<ellipse class="a" cx="%s" cy="%s" rx="7" ry="3.2" transform="rotate(%s %s %s)"/>' % (
            n(x), n(y), n(ang), n(x), n(y)))
    laurel = '<path class="st-a" stroke-width="2.4" d="M64 76 Q100 46 136 76"/>' + "".join(leaves)
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(86, 93, 7, 8, 4.6), eye(114, 93, 7, 8, 4.6))
    brows = ('<g class="zeus-brow"><path class="st-sh" stroke-width="8.5" d="M76 83 Q 86 77 95 83 M105 83 Q114 77 124 83"/>'
             '<path class="st-hb" stroke-width="6.5" d="M76 83 Q 86 77 95 83 M105 83 Q114 77 124 83"/></g>')
    head = ('<ellipse class="sk" cx="65" cy="98" rx="5" ry="8"/><ellipse class="sk" cx="135" cy="98" rx="5" ry="8"/>'
            '<ellipse class="sk" cx="100" cy="94" rx="34" ry="36"/>'
            + "".join('<circle class="sh" cx="%d" cy="%d" r="%s"/>' % (x, y, r) for x, y, r in [(82, 62, 13.5), (100, 58, 14.5), (118, 62, 13.5)])
            + "".join('<circle class="hb" cx="%d" cy="%d" r="%s"/>' % (x, y, r) for x, y, r in [(82, 62, 12), (100, 58, 13), (118, 62, 12)])
            + laurel + eyes + eye_states([(86, 93), (114, 93)], 5.5, 5, sw=3.2) + brows
            + '<path class="st-sh" stroke-width="2.5" d="M96.5 105 Q100 108 103.5 105"/>'
            + blush([(78, 106), (122, 106)], 5, 3.4)
            + '<path class="st-sh" stroke-width="3" d="%s"/><path class="hb" d="%s"/>' % (beard, beard)
            + '<path class="st-sh" stroke-width="2.2" d="M86 134 Q 88 146 94 154 M114 134 Q 112 146 106 154 M100 140 L100 157"/>'
            + mouth(100, 120.5, 12, sw=2.8)
            + '<path class="st-sh" stroke-width="3" d="%s"/><path class="hb" d="%s"/>' % (stache, stache))
    return hair + body + head + arm


# 6. Robot -----------------------------------------------------------------
@character("robot", "Rivet", "Robot",
           {"p": "#7B8CFF", "s": "#D5DBFF", "a": "#3DF5C8", "bg": "#E6E9FF"},
           """
.bh-av--robot{--look:4px}
.bh-av--robot .rob-ant{transform-origin:100px 52px;animation:rob-ant 2.8s ease-in-out infinite}
.bh-av--robot .rob-glow{opacity:.25;animation:rob-glow 1.6s ease-in-out infinite}
.bh-av--robot .rob-led{animation:rob-led 1.2s steps(1) infinite}
.bh-av--robot .rob-arm{transform-origin:66px 146px;animation:rob-arm 3s ease-in-out infinite}
.bh-av--robot[data-state="talking"] .bh-talk{animation:none}
.bh-av--robot .rob-bar{animation:rob-bar .42s ease-in-out infinite alternate}
.bh-av--robot .rob-bar.b2{animation-delay:-.12s}.bh-av--robot .rob-bar.b3{animation-delay:-.26s}
.bh-av--robot .rob-bar.b4{animation-delay:-.07s}.bh-av--robot .rob-bar.b5{animation-delay:-.33s}
.bh-av--robot[data-state="thinking"] .rob-bulb{animation:rob-led .5s steps(1) infinite}
.bh-av--robot[data-state="happy"] .rob-arm{animation:rob-cheer .45s ease-in-out infinite alternate}
@keyframes rob-ant{0%,100%{transform:rotate(-6deg)}50%{transform:rotate(6deg)}}
@keyframes rob-glow{0%,100%{opacity:.15;transform:scale(.8)}50%{opacity:.5;transform:scale(1.15)}}
@keyframes rob-led{50%{opacity:.25}}
@keyframes rob-arm{0%,100%{transform:rotate(0)}50%{transform:rotate(8deg)}}
@keyframes rob-bar{from{transform:scaleY(.25)}to{transform:scaleY(1)}}
@keyframes rob-cheer{to{transform:rotate(28deg)}}
""")
def draw_robot():
    ant = ('<g class="pv anim rob-ant"><path class="st-s" stroke-width="4" d="M100 52 L100 32"/>'
           '<circle class="a anim rob-glow" cx="100" cy="27" r="10"/><circle class="a rob-bulb anim" cx="100" cy="27" r="6"/>'
           '<circle class="w" cx="98" cy="25" r="1.8" opacity=".8"/></g>')
    arm = '<g class="pv anim rob-arm"><ellipse class="s" cx="64" cy="156" rx="8" ry="12"/><ellipse class="sh" cx="66" cy="160" rx="5" ry="7"/></g>'
    body = (arm + mirror(arm)
            + '<rect class="s" x="90" y="126" width="20" height="14" rx="3"/><rect class="sh" x="90" y="126" width="20" height="5"/>'
            + srect("p", 70, 138, 60, 42, 14)
            + '<rect class="s" x="85" y="148" width="30" height="18" rx="5"/>'
            '<circle class="a anim rob-led" cx="94" cy="157" r="3.2"/><circle class="sh" cx="106" cy="157" r="3.2"/>')
    ears = ('<rect class="s" x="46" y="78" width="14" height="30" rx="6"/><rect class="s" x="140" y="78" width="14" height="30" rx="6"/>'
            '<circle class="sh" cx="53" cy="93" r="3"/><circle class="sh" cx="147" cy="93" r="3"/>')
    def reye(cx, cy):
        return ('<g class="bh-eye"><g class="bh-look">'
                '<ellipse class="a" cx="%s" cy="%s" rx="11" ry="13" opacity=".22"/>'
                '<ellipse class="a" cx="%s" cy="%s" rx="7.5" ry="9.5"/>'
                '<ellipse class="w" cx="%s" cy="%s" rx="2.2" ry="2.8" opacity=".85"/></g></g>') % (
            n(cx), n(cy), n(cx), n(cy), n(cx + 2.5), n(cy - 3.5))
    bars = "".join('<rect class="a rob-bar b%d" x="%s" y="101" width="3.6" height="11" rx="1.8"/>' % (i + 1, n(86 + i * 6.6)) for i in range(5))
    head = (ears + srect("p", 56, 50, 88, 82, 24)
            + '<rect class="k" x="66" y="62" width="68" height="56" rx="16"/>'
            '<path class="w" opacity=".09" d="M72 72 Q 72 66 80 66 L 110 66 Q 88 72 72 94 Z"/>'
            + '<g class="bh-eyes">%s%s</g>' % (reye(84, 87), reye(116, 87))
            + eye_states([(84, 87), (116, 87)], 7, 6, cls="st-a", sw=3.4)
            + mouth(100, 104, 20,
                    smile='<path class="st-a" stroke-width="3.2" d="M90 104 Q100 111 110 104"/>',
                    talk=bars,
                    grin='<path class="a" d="M88 102 Q100 117 112 102 Z"/>')
            + blush([(73, 104), (127, 104)], 5, 3)
            + '<circle class="sh" cx="62" cy="58" r="2.2"/><circle class="sh" cx="138" cy="58" r="2.2"/>')
    return ant + body + head


# 7. Owl -------------------------------------------------------------------
@character("owl", "Sage", "Owl",
           {"p": "#8E6CD1", "s": "#F1E8FF", "a": "#FFB02E", "bg": "#F0EAFF"},
           """
.bh-av--owl{--look:3px}
.bh-av--owl .owl-wing{transform-origin:64px 104px;animation:owl-flap 4s ease-in-out infinite}
.bh-av--owl .owl-tuft{transform-origin:70px 62px;animation:owl-tuft 3s ease-in-out infinite}
.bh-av--owl .bh-eye{animation-duration:6s}
.bh-av--owl[data-state="happy"] .owl-wing{animation:owl-flutter .3s ease-in-out infinite alternate}
@keyframes owl-flap{0%,66%,100%{transform:rotate(0)}72%{transform:rotate(14deg)}78%{transform:rotate(0)}84%{transform:rotate(14deg)}90%{transform:rotate(0)}}
@keyframes owl-flutter{to{transform:rotate(22deg)}}
@keyframes owl-tuft{0%,100%{transform:rotate(0)}50%{transform:rotate(-5deg)}}
""")
def draw_owl():
    wing = ('<g class="pv anim owl-wing"><path class="p" d="M60 98 C 40 108, 32 138, 42 164 C 54 160, 64 144, 68 126 Z"/>'
            '<path class="sh" d="M60 98 C 40 108, 32 138, 42 164 C 54 160, 64 144, 68 126 Z"/>'
            '<path class="st-sh" stroke-width="2" d="M46 132 Q 52 128 58 130 M46 146 Q 51 142 56 144"/></g>')
    tuft = '<g class="pv anim owl-tuft"><path class="p" d="M62 78 L 55 46 Q 55 41 60 43 L 84 60 Z"/></g>'
    chev = []
    for y, xs in [(128, [88, 100, 112]), (140, [82, 94, 106, 118]), (152, [88, 100, 112])]:
        chev += ['M%d %d L%d %d L%d %d' % (x - 5, y, x, y + 4, x + 5, y) for x in xs]
    feet = "".join('<ellipse class="a" cx="%s" cy="171" rx="3.6" ry="5.8"/>' % n(x) for x in [83, 89, 95, 105, 111, 117])
    eyes = '<g class="bh-eyes">%s%s</g>' % (
        eye(81, 94, 14, 14, 5.2, iris="a", iris_r=9), eye(119, 94, 14, 14, 5.2, iris="a", iris_r=9))
    return (wing + mirror(wing) + tuft + mirror(tuft.replace("owl-tuft", "owl-tuft")) + sell("p", 100, 112, 48, 58)
            + '<ellipse class="hl" cx="72" cy="72" rx="9" ry="5" transform="rotate(-35 72 72)"/>'
            + '<ellipse class="s" cx="100" cy="142" rx="30" ry="26"/>'
            + '<path class="st-sh" stroke-width="2.2" d="%s"/>' % " ".join(chev)
            + feet
            + '<circle class="s" cx="81" cy="94" r="21"/><circle class="s" cx="119" cy="94" r="21"/>'
            + eyes + eye_states([(81, 94), (119, 94)], 9, 7, sw=3.8)
            + mouth(100, 112, 10, smile='',
                    talk='<ellipse class="k" cx="100" cy="117" rx="5" ry="4.5"/>',
                    grin='<path class="k" d="M94 113 L106 113 L100 123 Z"/>')
            + '<path class="a" style="stroke:var(--a);stroke-width:3;stroke-linejoin:round" d="M94 106 Q100 104 106 106 L100 117 Z"/>'
            + '<path class="sh" d="M100 111 L106 106 L100 117 Z"/>'
            + blush([(66, 112), (134, 112)], 6, 3.6))


# 8. Octopus ---------------------------------------------------------------
@character("octopus", "Inky", "Octopus",
           {"p": "#FF6F91", "s": "#FFD1DC", "a": "#5CE1E6", "bg": "#FFEAF0"},
           """
.bh-av--octopus{--look:3px}
.bh-av--octopus .oct-t{animation:oct-wave 2.6s ease-in-out infinite alternate}
.bh-av--octopus[data-state="happy"] .oct-t{animation-duration:.5s}
.bh-av--octopus[data-state="talking"] .oct-t{animation-duration:1.2s}
.bh-av--octopus .oct-b{opacity:0;animation:oct-bub 3.6s ease-in infinite}
.bh-av--octopus .oct-b2{animation-delay:-1.2s}.bh-av--octopus .oct-b3{animation-delay:-2.4s}
@keyframes oct-wave{from{transform:rotate(-6deg)}to{transform:rotate(6deg)}}
@keyframes oct-bub{0%{transform:translateY(12px) scale(.5);opacity:0}20%{opacity:.9}100%{transform:translateY(-34px) scale(1);opacity:0}}
""")
def draw_octopus():
    t = [
        ("M74 118 C 58 136, 44 146, 34 136 C 28 130, 32 122, 40 124", 74, 118, 0.0, True),
        ("M126 118 C 142 136, 156 146, 166 136 C 172 130, 168 122, 160 124", 126, 118, -1.3, True),
        ("M84 124 C 78 146, 72 162, 58 166 C 50 168, 48 160, 54 156", 84, 124, -0.6, False),
        ("M116 124 C 122 146, 128 162, 142 166 C 150 168, 152 160, 146 156", 116, 124, -1.9, False),
        ("M95 128 C 95 150, 92 168, 82 176 C 76 180, 72 174, 76 170", 95, 128, -0.9, False),
        ("M105 128 C 105 150, 108 168, 118 176 C 124 180, 128 174, 124 170", 105, 128, -2.2, False),
    ]
    tent = ""
    for d, ox, oy, delay, back in t:
        shade = '<path class="st-sh" stroke-width="13" d="%s"/>' % d if back else ""
        tent += ('<g class="pv anim oct-t" style="transform-origin:%dpx %dpx;animation-delay:%ss">'
                 '<path class="st-p" stroke-width="13" d="%s"/>%s</g>') % (ox, oy, n(delay), d, shade)
    head = ('<path class="p" d="M52 104 C 52 62, 74 38, 100 38 C 126 38, 148 62, 148 104 C 148 124, 128 134, 100 134 C 72 134, 52 124, 52 104 Z"/>'
            '<path class="sh" d="M132 56 C 144 70, 148 86, 148 104 C 148 124, 128 134, 100 134 C 118 128, 136 118, 138 100 C 140 84, 138 68, 132 56 Z"/>'
            '<ellipse class="hl" cx="77" cy="60" rx="11" ry="7" transform="rotate(-35 77 60)"/>'
            '<circle class="s" cx="121" cy="55" r="5" opacity=".75"/><circle class="s" cx="133" cy="70" r="3.2" opacity=".75"/>'
            '<circle class="s" cx="111" cy="46" r="2.8" opacity=".75"/>')
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(84, 95, 10, 11, 6.5), eye(116, 95, 10, 11, 6.5))
    bubbles = ('<g class="oct-bubbles">'
               '<circle class="st-a anim oct-b" stroke-width="2" cx="44" cy="80" r="4.5"/>'
               '<circle class="st-a anim oct-b oct-b2" stroke-width="2" cx="36" cy="92" r="3"/>'
               '<circle class="st-a anim oct-b oct-b3" stroke-width="2" cx="50" cy="94" r="3.6"/></g>')
    return (tent + head + eyes + eye_states([(84, 95), (116, 95)], 7, 6)
            + mouth(100, 113, 13) + blush([(70, 109), (130, 109)]) + bubbles)


# 9. Fox -------------------------------------------------------------------
@character("fox", "Kit", "Fox",
           {"p": "#F2743B", "s": "#FFF4E8", "a": "#2EC4B6", "bg": "#FFEBDD"},
           """
.bh-av--fox{--look:2.5px}
.bh-av--fox .fox-tail{transform-origin:124px 162px;animation:fox-swish 2.4s ease-in-out infinite alternate}
.bh-av--fox .fox-ear{transform-origin:76px 66px;animation:fox-twitch 4.4s ease-in-out infinite}
.bh-av--fox .fox-ear-r{animation-delay:-2s}
.bh-av--fox .fox-scarf{transform-origin:106px 154px;animation:fox-scarf 2s ease-in-out infinite alternate}
.bh-av--fox[data-state="happy"] .fox-tail{animation-duration:.45s}
.bh-av--fox[data-state="listening"] .fox-ear{animation:none;transform:rotate(5deg)}
@keyframes fox-swish{from{transform:rotate(-5deg)}to{transform:rotate(7deg)}}
@keyframes fox-twitch{0%,84%,100%{transform:rotate(0)}88%{transform:rotate(-9deg)}92%{transform:rotate(0)}}
@keyframes fox-scarf{from{transform:rotate(-4deg)}to{transform:rotate(6deg)}}
""")
def draw_fox():
    tail = ('<g class="pv anim fox-tail"><path class="p" d="M122 168 C 150 172, 172 152, 170 122 C 169 106, 158 96, 148 100 C 156 118, 150 142, 124 152 Z"/>'
            '<path class="s" d="M170 122 C 169 106, 158 96, 148 100 C 151 108, 153 116, 153 124 C 159 127, 166 126, 170 122 Z"/></g>')
    scarf_tail = '<g class="pv anim fox-scarf"><path class="a" d="M110 152 L124 172 Q118 177 111 174 L102 156 Z"/><path class="sh" d="M110 152 L124 172 Q118 177 111 174 L102 156 Z"/></g>'
    body = ('<path class="p" d="M68 180 C 64 158, 80 144, 100 144 C 120 144, 136 158, 132 180 Q 100 187 68 180 Z"/>'
            '<ellipse class="s" cx="100" cy="163" rx="13" ry="15"/>'
            '<ellipse class="k" cx="87" cy="179" rx="9" ry="6"/><ellipse class="k" cx="113" cy="179" rx="9" ry="6"/>'
            + scarf_tail +
            '<path class="a" d="M70 140 Q100 154 130 140 L130 149 Q100 164 70 149 Z"/>'
            '<path class="st-sh" stroke-width="2" d="M78 147 Q100 158 122 147"/>')
    ear = ('<g class="pv anim fox-ear"><path class="p" d="M56 82 L 58 28 Q 60 22 66 26 L 98 58 Z"/>'
           '<path class="k" d="M57.4 44 L 58 28 Q 60 22 66 26 L 76 36 Z"/>'
           '<path class="s" d="M64 72 L 65 46 L 85 61 Z"/></g>')
    headp = "M50 86 C 50 64, 72 50, 100 50 C 128 50, 150 64, 150 86 C 150 100, 142 110, 132 116 L 110 132 Q 100 138 90 132 L 68 116 C 58 110, 50 100, 50 86 Z"
    mask = "M54 98 C 62 110, 80 110, 90 104 Q 100 100 110 104 C 120 110, 138 110, 146 98 C 144 106, 138 112, 132 116 L 110 132 Q 100 138 90 132 L 68 116 C 62 112, 56 106, 54 98 Z"
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(82, 89, 8, 9, 5.5), eye(118, 89, 8, 9, 5.5))
    head = ('<path class="p" d="%s"/>' % headp
            + '<path class="sh" d="M134 60 C 144 68, 150 76, 150 86 C 150 100, 142 110, 132 116 C 138 104, 142 84, 134 60 Z"/>'
            '<ellipse class="hl" cx="80" cy="64" rx="11" ry="5" transform="rotate(-20 80 64)"/>'
            + '<path class="s" d="%s"/>' % mask
            + eyes + eye_states([(82, 89), (118, 89)], 6.5, 5.5)
            + mouth(100, 125, 14,
                    smile='<path class="st-k" stroke-width="2.4" d="M100 120 L100 124 M93 125 Q96.5 129 100 124 Q103.5 129 107 125"/>',
                    talk='<ellipse class="k" cx="100" cy="129" rx="5" ry="4.5"/><ellipse class="pk" cx="100" cy="131.5" rx="2.8" ry="1.4"/>',
                    grin='<path class="k" d="M92 124 Q100 137 108 124 Z"/><ellipse class="pk" cx="100" cy="129" rx="3.2" ry="1.6"/>')
            + '<ellipse class="k" cx="100" cy="116" rx="6.5" ry="5"/><ellipse class="w" cx="97.5" cy="114.5" rx="2" ry="1.2" opacity=".6"/>'
            + blush([(68, 106), (132, 106)]))
    return tail + body + ear + mirror(ear.replace("fox-ear", "fox-ear fox-ear-r")) + head


# 10. Dragon ---------------------------------------------------------------
@character("dragon", "Ember", "Baby dragon",
           {"p": "#45C486", "s": "#E9F9C8", "a": "#FF8A3D", "bg": "#E6F8EE"},
           """
.bh-av--dragon{--look:3px}
.bh-av--dragon .drg-wing{transform-origin:72px 138px;animation:drg-flap 2.4s ease-in-out infinite}
.bh-av--dragon .drg-tail{transform-origin:126px 170px;animation:drg-tail 1.8s ease-in-out infinite alternate}
.bh-av--dragon .drg-fin{transform-origin:58px 94px;animation:drg-fin 3s ease-in-out infinite}
.bh-av--dragon .drg-puff{opacity:0;transition:opacity .2s}
.bh-av--dragon[data-state="happy"] .drg-puff{opacity:1}
.bh-av--dragon[data-state="happy"] .drg-wing{animation-duration:.4s}
.bh-av--dragon .drg-puff .pl{animation:drg-puff-l 1.4s ease-out infinite}
.bh-av--dragon .drg-puff .pr{animation:drg-puff-r 1.4s ease-out infinite}
.bh-av--dragon .drg-puff .d2{animation-delay:-.7s}
@keyframes drg-flap{0%,100%{transform:rotate(0)}50%{transform:rotate(10deg)}}
@keyframes drg-tail{from{transform:rotate(-6deg)}to{transform:rotate(8deg)}}
@keyframes drg-fin{0%,100%{transform:rotate(0)}50%{transform:rotate(-8deg)}}
@keyframes drg-puff-l{0%{transform:translate(0,0) scale(.4);opacity:0}25%{opacity:.95}100%{transform:translate(-12px,-26px) scale(1.25);opacity:0}}
@keyframes drg-puff-r{0%{transform:translate(0,0) scale(.4);opacity:0}25%{opacity:.95}100%{transform:translate(12px,-26px) scale(1.25);opacity:0}}
""")
def draw_dragon():
    wing = ('<g class="pv anim drg-wing"><path class="a" d="M72 138 L 28 98 C 33 108, 33 117, 29 125 C 39 123, 45 129, 45 137 C 53 135, 59 141, 61 149 Z"/>'
            '<path class="sh" d="M29 125 C 39 123, 45 129, 45 137 C 53 135, 59 141, 61 149 L 72 138 Z"/>'
            '<path class="st-p" stroke-width="5" d="M72 138 L 28 98"/></g>')
    tail = ('<g class="pv anim drg-tail"><path class="st-p" stroke-width="10" d="M126 170 C 146 174, 158 166, 162 152"/>'
            '<path class="a" style="stroke:var(--a);stroke-width:2;stroke-linejoin:round" d="M162 139 L 171 156 L 153 154 Z"/></g>')
    body = ('<path class="p" d="M68 180 C 64 156, 80 140, 100 140 C 120 140, 136 156, 132 180 Q 100 187 68 180 Z"/>'
            '<ellipse class="s" cx="100" cy="164" rx="18" ry="17"/>'
            '<path class="st-sh" stroke-width="2.2" d="M84 158 Q100 162 116 158 M83 168 Q100 172 117 168"/>'
            '<ellipse class="p" cx="85" cy="179" rx="10" ry="6"/><ellipse class="p" cx="115" cy="179" rx="10" ry="6"/>'
            '<path class="st-sh" stroke-width="1.8" d="M81 176 L81 181 M89 176 L89 181 M111 176 L111 181 M119 176 L119 181"/>')
    horn = ('<path class="s" d="M74 64 C 66 50, 62 38, 56 30 C 70 34, 82 46, 88 58 Z"/>'
            '<path class="st-sh" stroke-width="2" d="M66 46 L74 44 M70 54 L78 52"/>')
    crest = ('<path class="a" d="M93 57 L100 38 L107 57 Z"/><path class="a" d="M80 61 L84 48 L91 58 Z"/>'
             '<path class="a" d="M120 61 L116 48 L109 58 Z"/>')
    fin = '<g class="pv anim drg-fin"><path class="a" d="M58 86 L 36 76 L 44 92 L 34 104 L 58 100 Z"/><path class="sh" d="M58 94 L 44 92 L 34 104 L 58 100 Z"/></g>'
    eyes = '<g class="bh-eyes">%s%s</g>' % (eye(80, 88, 10, 11, 6.5), eye(120, 88, 10, 11, 6.5))
    head = (sell("p", 100, 96, 46, 42)
            + '<ellipse class="hl" cx="80" cy="66" rx="10" ry="5" transform="rotate(-25 80 66)"/>'
            '<ellipse class="hl" cx="100" cy="117" rx="27" ry="16"/>'
            '<ellipse class="k" cx="92" cy="110" rx="2.6" ry="2" opacity=".7"/><ellipse class="k" cx="108" cy="110" rx="2.6" ry="2" opacity=".7"/>'
            + eyes + eye_states([(80, 88), (120, 88)], 7, 6)
            + mouth(100, 122, 16) + blush([(68, 107), (132, 107)]))
    puff = ('<g class="drg-puff"><circle class="smk pl" cx="90" cy="104" r="4.5"/><circle class="smk pr" cx="110" cy="104" r="4.5"/>'
            '<circle class="smk pl d2" cx="90" cy="104" r="3.5"/><circle class="smk pr d2" cx="110" cy="104" r="3.5"/></g>')
    return (wing + mirror(wing) + tail + body + horn + mirror(horn) + crest + fin + mirror(fin) + head + puff)


# ---------------------------------------------------------------------------
# BITS: geometric bots with a modular face.
#   data-eyes    round | dot | pill | square | lidded | visor | cyclops
#   data-mouth   smile | cat | flat | fang | none
#   data-acc     none | antenna | sprout | halo | crown | bow | headset
#   data-cheeks  on | off
# The face is drawn once in local coordinates (eyes at x = +/-16) and placed on
# each shape with translate/scale, so every option works on every Bit.
# ---------------------------------------------------------------------------
EYE_STYLES = ["round", "dot", "pill", "square", "lidded", "visor", "cyclops"]
MOUTH_STYLES = ["smile", "cat", "flat", "fang", "none"]
ACCESSORIES = ["none", "antenna", "sprout", "halo", "crown", "bow", "headset"]
TWO_EYE = ["round", "dot", "pill", "square", "lidded"]

BITS_CSS = (
    ".bh-bits .fs{fill:var(--face,var(--p))}"
    ".bh-bits .bb-fi{translate:calc(var(--lx,0) * 2px) calc(var(--ly,0) * 1.6px);transition:translate .25s ease-out}"
    '.bh-bits[data-state="thinking"] .bb-fi{translate:1.6px -2px}'
    ".bh-bits .ev,.bh-bits .eg-visor,.bh-bits .eg-cyc,.bh-bits .mv,.bh-bits .acc{display:none}"
    + "".join('.bh-bits[data-eyes="%s"] .ev-%s{display:inline}' % (e, e) for e in TWO_EYE)
    + '.bh-bits[data-eyes="visor"] .eg-two,.bh-bits[data-eyes="cyclops"] .eg-two{display:none}'
    '.bh-bits[data-eyes="visor"] .eg-visor,.bh-bits[data-eyes="cyclops"] .eg-cyc{display:inline}'
    + "".join('.bh-bits[data-mouth="%s"] .mv-%s{display:inline}' % (m, m) for m in MOUTH_STYLES)
    + "".join('.bh-bits[data-acc="%s"] .acc-%s{display:inline}' % (a, a) for a in ACCESSORIES)
    + '.bh-bits[data-cheeks="off"] .bh-blush{display:none}'
    ".bh-bits .ant{transform-origin:0 3px;animation:bb-ant 2.2s ease-in-out infinite}"
    ".bh-bits .spr{transform-origin:0 3px;animation:bb-spr 3s ease-in-out infinite}"
    ".bh-bits .hal{animation:bb-halo 2.6s ease-in-out infinite}"
    ".bh-bits .bow{transform-origin:0 -6px;animation:bb-bow 3.4s ease-in-out infinite}"
    ".bh-bits .acc-crown .gl{animation:bh-twinkle 2.4s ease-in-out infinite}"
    ".bh-bits .mic{opacity:.4}"
    '.bh-bits[data-state="talking"] .mic{opacity:1;animation:bb-blink .5s steps(1) infinite}'
    '.bh-bits[data-state="happy"] .ant{animation-duration:.45s}'
    '.bh-bits[data-state="happy"] .spr{animation-duration:.6s}'
    '.bh-bits[data-state="listening"] .ant{animation:none;transform:rotate(12deg)}'
    "@keyframes bb-ant{0%,100%{transform:rotate(-9deg)}50%{transform:rotate(9deg)}}"
    "@keyframes bb-spr{0%,100%{transform:rotate(-6deg)}50%{transform:rotate(7deg)}}"
    "@keyframes bb-halo{0%,100%{transform:translateY(0)}50%{transform:translateY(-4px)}}"
    "@keyframes bb-bow{0%,80%,100%{transform:rotate(0)}86%{transform:rotate(-10deg)}92%{transform:rotate(6deg)}}"
    "@keyframes bb-blink{50%{opacity:.3}}"
)


def _two(fn):
    return "".join(fn(x) for x in (-16, 16))


def bit_face(cx, cy, s=1.0):
    ev = {
        "round": _two(lambda x: '<g class="bh-eye"><circle class="w" cx="%d" cy="0" r="10"/><g class="bh-look">'
                                 '<circle class="k" cx="%d" cy=".5" r="5.8"/><circle class="w" cx="%s" cy="-1.8" r="2"/></g></g>'
                                 % (x, x, n(x + 2.2))),
        "dot": _two(lambda x: '<g class="bh-eye"><g class="bh-look"><circle class="k" cx="%d" cy="0" r="6.2"/>'
                               '<circle class="w" cx="%s" cy="-2.1" r="1.9"/></g></g>' % (x, n(x + 2.1))),
        "pill": _two(lambda x: '<g class="bh-eye"><g class="bh-look"><rect class="k" x="%s" y="-10.5" width="9.6" height="21" rx="4.8"/>'
                                '<ellipse class="w" cx="%s" cy="-5.6" rx="1.8" ry="2.6"/></g></g>' % (n(x - 4.8), n(x + 1.4))),
        "square": _two(lambda x: '<g class="bh-eye"><g class="bh-look"><rect class="k" x="%s" y="-6.5" width="13" height="13" rx="3.6"/>'
                                  '<rect class="w" x="%s" y="-4.4" width="3.2" height="3.2" rx="1"/></g></g>' % (n(x - 6.5), n(x + 0.6))),
        "lidded": _two(lambda x: '<g class="bh-eye"><circle class="w" cx="%d" cy="0" r="10"/><g class="bh-look">'
                                  '<circle class="k" cx="%d" cy="2.2" r="5.6"/><circle class="w" cx="%s" cy=".4" r="1.8"/></g>'
                                  '<path class="fs" d="M%s -3 A11 11 0 0 1 %s -3 Z"/>'
                                  '<path class="st-k" stroke-width="2.4" d="M%s -3 L%s -3"/></g>'
                                  % (x, x, n(x + 2), n(x - 10.58), n(x + 10.58), n(x - 9.3), n(x + 9.3))),
    }
    two = ('<g class="eg-two"><g class="bh-eyes">%s</g>%s</g>' % (
        "".join('<g class="ev ev-%s">%s</g>' % (k, v) for k, v in ev.items()),
        eye_states([(-16, 0), (16, 0)], 7.5, 6.5)))
    veye = lambda x: ('<g class="bh-eye"><g class="bh-look"><ellipse class="a" cx="%d" cy="0" rx="9.5" ry="8" opacity=".25"/>'
                      '<ellipse class="a" cx="%d" cy="0" rx="6.2" ry="5.2"/><ellipse class="w" cx="%s" cy="-2" rx="1.8" ry="1.4" opacity=".8"/></g></g>'
                      % (x, x, n(x + 2)))
    visor = ('<g class="eg-visor"><rect class="k" x="-31" y="-12.5" width="62" height="25" rx="12.5"/>'
             '<path class="w" opacity=".1" d="M-24 -8.5 L8 -8.5 L1 -3 L-27 -3 Z"/>'
             '<g class="bh-eyes">%s%s</g>%s</g>' % (veye(-13), veye(13), eye_states([(-13, 0), (13, 0)], 6, 5, cls="st-a", sw=3.2)))
    cyc = ('<g class="eg-cyc"><g class="bh-eyes"><g class="bh-eye"><circle class="w" cx="0" cy="0" r="15.5"/><g class="bh-look">'
           '<circle class="a" cx="0" cy="0" r="9.2"/><circle class="k" cx="0" cy="0" r="4.9"/><circle class="w" cx="3.2" cy="-3.2" r="2.5"/>'
           '</g></g></g>%s</g>' % eye_states([(0, 0)], 11, 9, sw=4))
    grin = '<path class="k" d="M-10 -1 Q0 16 10 -1 Z"/><ellipse class="pk" cx="0" cy="5.6" rx="3.8" ry="1.9"/>'
    talk = '<ellipse class="k" cx="0" cy="3.4" rx="5.4" ry="5.4"/><ellipse class="pk" cx="0" cy="6" rx="3" ry="1.6"/>'
    arc = '<path class="st-k" stroke-width="3.2" d="M-8 0 Q0 7 8 0"/>'
    fang = '<path class="w" d="M2.2 3 L5.9 2.2 L4.5 6.4 Z"/>'
    mouths = {
        "smile": (arc, talk, grin),
        "cat": ('<path class="st-k" stroke-width="2.8" d="M-8 0 Q-4 5 0 0 Q4 5 8 0"/>', talk, grin),
        "flat": ('<path class="st-k" stroke-width="3.2" d="M-6 1.5 L6 1.5"/>',
                 '<ellipse class="k" cx="0" cy="3" rx="4.4" ry="4.4"/>', arc),
        "fang": (arc + fang, talk, grin + '<path class="w" d="M3 -.6 L7 -.6 L5.2 3.6 Z"/>'),
        "none": ("", '<ellipse class="k" cx="0" cy="2" rx="3.8" ry="3.8"/>',
                 '<path class="st-k" stroke-width="2.6" d="M-5 0 Q0 4 5 0"/>'),
    }
    mouth_markup = "".join(
        '<g class="mv mv-%s"><g class="bh-smile">%s</g><g class="bh-talk">%s</g><g class="bh-grin">%s</g></g>' % (k, a, b, c)
        for k, (a, b, c) in mouths.items())
    cheeks = blush([(-27, 11), (27, 11)], 6, 3.6)
    return ('<g class="bb-face" transform="translate(%s %s) scale(%s)"><g class="bb-fi">%s%s%s%s'
            '<g transform="translate(0 19)">%s</g></g></g>') % (n(cx), n(cy), n(s), cheeks, two, visor, cyc, mouth_markup)


def bit_acc(tx, ty, w, dy):
    d = dy
    headset = ('<path class="st-k" stroke-width="5" d="M%s %s C %s -30, %s -30, %s %s"/>' % (-w, d - 12, -w, w, w, d - 12)
               + "".join('<rect class="k" x="%s" y="%s" width="14" height="28" rx="7"/><rect class="a" x="%s" y="%s" width="6" height="16" rx="3"/>'
                         % (n(x - 7), n(d - 14), n(x - 3), n(d - 8)) for x in (-w, w))
               + '<path class="st-k" stroke-width="3" d="M%s %s Q %s %s %s %s"/><circle class="a mic" cx="%s" cy="%s" r="3.8"/>'
               % (n(-w + 3), n(d + 10), n(-w + 5), n(d + 26), n(-w + 22), n(d + 28), n(-w + 25), n(d + 28)))
    parts = {
        "antenna": ('<g class="pv anim ant"><path class="st-k" stroke-width="3.2" d="M0 4 L0 -16"/>'
                    '<circle class="a" cx="0" cy="-22" r="6.5"/><circle class="w" cx="-2.2" cy="-24.2" r="2" opacity=".75"/></g>'),
        "sprout": ('<g class="pv anim spr"><path class="st-a" stroke-width="3.2" d="M0 4 Q -2 -7 0 -15"/>'
                   '<ellipse class="a" cx="-8.5" cy="-17" rx="9" ry="4.8" transform="rotate(28 -8.5 -17)"/>'
                   '<ellipse class="a" cx="8.5" cy="-20" rx="9" ry="4.8" transform="rotate(-28 8.5 -20)"/>'
                   '<ellipse class="sh" cx="8.5" cy="-20" rx="9" ry="4.8" transform="rotate(-28 8.5 -20)"/></g>'),
        "halo": ('<g class="anim hal"><ellipse class="st-a" stroke-width="8" opacity=".22" cx="0" cy="-16" rx="23" ry="6.5"/>'
                 '<ellipse class="st-a" stroke-width="3.8" cx="0" cy="-16" rx="23" ry="6.5"/></g>'),
        "crown": ('<path class="a" style="stroke:var(--a);stroke-width:3;stroke-linejoin:round" d="M-17 5 L-19 -15 L-9 -6 L0 -20 L9 -6 L19 -15 L17 5 Z"/>'
                  '<path class="sh" d="M-17 -1 L17 -1 L17 5 L-17 5 Z"/><circle class="w" cx="0" cy="-4" r="2.6"/>'
                  '<path class="w gl anim" d="%s"/>' % star(-10, -11, 3.2)),
        "bow": ('<g class="pv anim bow"><path class="a" d="M0 -6 C -6 -17, -21 -19, -21 -6 C -21 7, -6 5, 0 -6 Z"/>'
                '<path class="a" d="M0 -6 C 6 -17, 21 -19, 21 -6 C 21 7, 6 5, 0 -6 Z"/>'
                '<ellipse class="sh" cx="-13" cy="-6" rx="4" ry="3.2"/><ellipse class="sh" cx="13" cy="-6" rx="4" ry="3.2"/>'
                '<circle class="a" cx="0" cy="-6" r="5.2"/><circle class="sh" cx="0" cy="-6" r="5.2"/></g>'),
        "headset": headset,
    }
    return '<g class="bb-acc" transform="translate(%s %s)">%s</g>' % (
        n(tx), n(ty), "".join('<g class="acc acc-%s">%s</g>' % (k, v) for k, v in parts.items()))


def bit(cid, name, role, colors, face, css=""):
    """Register a Bit. face = (eyes, mouth, accessory)."""
    def deco(fn):
        CHARACTERS.append({"id": cid, "name": name, "role": role, "colors": colors, "css": css, "draw": fn,
                           "family": "bits", "face": {"eyes": face[0], "mouth": face[1], "accessory": face[2]}})
        return fn
    return deco


# B1. Orb ------------------------------------------------------------------
@bit("orb", "Bop", "Orb bot", {"p": "#FF6B4A", "s": "#FFD3C4", "a": "#FFD23F", "bg": "#FFEDE7"},
     ("round", "smile", "antenna"), """
.bh-av--orb .orb-roll{transform-origin:100px 110px;animation:orb-roll 4s ease-in-out infinite}
.bh-av--orb[data-state="happy"] .orb-roll{animation:orb-spin .8s ease-in-out infinite}
@keyframes orb-roll{0%,100%{transform:rotate(-3deg)}50%{transform:rotate(3deg)}}
@keyframes orb-spin{0%,100%{transform:rotate(-6deg)}50%{transform:rotate(6deg)}}
""")
def draw_orb():
    return ('<g class="pv anim orb-roll">' + sell("p", 100, 110, 58, 58, k=5)
            + '<ellipse class="hl" cx="77" cy="78" rx="14" ry="8" transform="rotate(-35 77 78)"/>'
            + bit_face(100, 106, 1.2) + bit_acc(100, 52, 61, 58) + '</g>')


# B2. Cube -----------------------------------------------------------------
@bit("cube", "Blok", "Cube bot", {"p": "#4D7CFE", "s": "#BFD0FF", "a": "#FF7AB6", "bg": "#E6EEFF"},
     ("visor", "flat", "headset"), """
.bh-av--cube .cube-hop{transform-origin:100px 168px;animation:cube-hop 4.4s ease-in-out infinite}
.bh-av--cube[data-state="happy"] .cube-hop{animation-duration:1.1s}
@keyframes cube-hop{0%,68%,100%{transform:none}74%{transform:scale(1.06,.92)}82%{transform:translateY(-7px) scale(.97,1.04)}90%{transform:scale(1.03,.97)}96%{transform:none}}
""")
def draw_cube():
    return ('<g class="pv anim cube-hop">' + srect("p", 44, 58, 112, 110, 32, k=5)
            + '<rect class="s" x="68" y="150" width="64" height="7" rx="3.5" opacity=".7"/>'
            '<circle class="s" cx="62" cy="76" r="3.4"/><circle class="s" cx="138" cy="76" r="3.4"/>'
            '<ellipse class="hl" cx="70" cy="70" rx="12" ry="5" transform="rotate(-20 70 70)"/>'
            + bit_face(100, 108, 1.2) + bit_acc(100, 58, 58, 54) + '</g>')


# B3. Wedge ----------------------------------------------------------------
@bit("wedge", "Wedge", "Wedge bot", {"p": "#2EC27E", "s": "#B8F0D2", "a": "#FFC43D", "bg": "#E3F7EC"},
     ("dot", "cat", "sprout"), """
.bh-av--wedge .wedge-rock{transform-origin:100px 169px;animation:wedge-rock 3.2s ease-in-out infinite}
.bh-av--wedge[data-state="happy"] .wedge-rock{animation-duration:.7s}
@keyframes wedge-rock{0%,100%{transform:rotate(-4deg)}50%{transform:rotate(4deg)}}
""")
def draw_wedge():
    tri = "M100 50 L152 156 L48 156 Z"
    return ('<g class="pv anim wedge-rock">'
            '<path class="p" style="stroke:var(--p);stroke-width:26;stroke-linejoin:round" d="%s"/>' % tri
            + '<rect class="s" x="54" y="150" width="92" height="12" rx="6" opacity=".75"/>'
            '<ellipse class="hl" cx="86" cy="80" rx="6" ry="13" transform="rotate(26 86 80)"/>'
            + bit_face(100, 120, 1.08) + bit_acc(100, 37, 40, 66) + '</g>')


# B4. Hex ------------------------------------------------------------------
def _hexpts(cx, cy, r):
    import math
    return " ".join("%s %s" % (n(cx + r * math.cos(math.radians(a))), n(cy + r * math.sin(math.radians(a))))
                    for a in (-90, -30, 30, 90, 150, 210))


@bit("hex", "Hexo", "Hex bot", {"p": "#FFAE1F", "s": "#FFE6A8", "a": "#6E5BFF", "bg": "#FFF4DD"},
     ("square", "smile", "crown"), """
.bh-av--hex .hex-turn{transform-origin:100px 108px;animation:hex-turn 5s ease-in-out infinite}
.bh-av--hex[data-state="happy"] .hex-turn{animation:hex-flip .9s ease-in-out infinite}
@keyframes hex-turn{0%,100%{transform:rotate(-5deg)}50%{transform:rotate(5deg)}}
@keyframes hex-flip{0%,100%{transform:rotate(0)}50%{transform:rotate(30deg)}}
""")
def draw_hex():
    pts = _hexpts(100, 108, 56).split(" ")
    path = "M" + " L".join("%s %s" % (pts[i], pts[i + 1]) for i in range(0, 12, 2)) + " Z"
    ipts = _hexpts(100, 108, 45).split(" ")
    ipath = "M" + " L".join("%s %s" % (ipts[i], ipts[i + 1]) for i in range(0, 12, 2)) + " Z"
    return ('<g class="pv anim hex-turn">'
            '<path class="p" style="stroke:var(--p);stroke-width:16;stroke-linejoin:round" d="%s"/>' % path
            + '<path class="st-s" stroke-width="3" opacity=".75" d="%s"/>' % ipath
            + '<ellipse class="hl" cx="72" cy="78" rx="10" ry="5" transform="rotate(-30 72 78)"/>'
            + bit_face(100, 106, 1.1) + bit_acc(100, 44, 58, 64) + '</g>')


# B5. Drop -----------------------------------------------------------------
@bit("drop", "Drip", "Drop bot", {"p": "#22B8F0", "s": "#BDEBFF", "a": "#FF8A5B", "bg": "#E2F6FF"},
     ("pill", "smile", "none"), """
.bh-av--drop .drop-jelly{transform-origin:100px 172px;animation:drop-jelly 2.6s ease-in-out infinite}
.bh-av--drop[data-state="happy"] .drop-jelly{animation-duration:.6s}
@keyframes drop-jelly{0%,100%{transform:scale(1,1)}50%{transform:scale(1.045,.955)}}
""")
def draw_drop():
    body = "M100 36 C 118 64, 158 96, 158 124 C 158 154, 132 172, 100 172 C 68 172, 42 154, 42 124 C 42 96, 82 64, 100 36 Z"
    return ('<g class="pv anim drop-jelly"><path class="p" d="%s"/>' % body
            + '<path class="sh" d="M140 98 C 152 110, 158 118, 158 124 C 158 154, 132 172, 100 172 C 124 166, 147 150, 147 124 C 147 114, 145 106, 140 98 Z"/>'
            '<ellipse class="s" cx="100" cy="159" rx="26" ry="7" opacity=".55"/>'
            '<ellipse class="hl" cx="78" cy="100" rx="7" ry="15" transform="rotate(24 78 100)"/>'
            '<circle class="hl" cx="86" cy="76" r="3.5"/>'
            + bit_face(100, 126, 1.1) + bit_acc(100, 36, 56, 76) + '</g>')


# B6. Capsule --------------------------------------------------------------
@bit("capsule", "Tic", "Capsule bot", {"p": "#A259FF", "s": "#E2CCFF", "a": "#3BE8B0", "bg": "#F1E8FF"},
     ("lidded", "flat", "antenna"), """
.bh-av--capsule .cap-tilt{transform-origin:100px 172px;animation:cap-tilt 3.4s ease-in-out infinite}
.bh-av--capsule[data-state="happy"] .cap-tilt{animation-duration:.8s}
@keyframes cap-tilt{0%,100%{transform:rotate(-6deg)}50%{transform:rotate(6deg)}}
""")
def draw_capsule():
    return ('<g class="pv anim cap-tilt">'
            '<rect class="s" x="62" y="38" width="76" height="134" rx="38"/>'
            '<path class="sh" d="M138 110 L138 134 A38 38 0 0 1 100 172 A38 38 0 0 0 128 134 L128 110 Z"/>'
            '<path class="p" d="M62 110 L62 76 A38 38 0 0 1 138 76 L138 110 Z"/>'
            '<path class="sh" d="M128 50 A38 38 0 0 1 138 76 L138 110 L128 110 L128 76 Q 128 62 128 50 Z"/>'
            '<path class="st-sh" stroke-width="2.4" d="M62 110 L138 110"/>'
            '<ellipse class="hl" cx="76" cy="72" rx="5" ry="14"/>'
            '<circle class="hl" cx="84" cy="136" r="3"/><circle class="hl" cx="112" cy="148" r="2.4"/><circle class="hl" cx="98" cy="158" r="2"/>'
            + bit_face(100, 86, 0.92) + bit_acc(100, 38, 43, 52) + '</g>')


# B7. Cloud ----------------------------------------------------------------
@bit("cloud", "Puff", "Cloud bot", {"p": "#9BB0FF", "s": "#E4EAFF", "a": "#FFD166", "bg": "#EEF1FF"},
     ("dot", "smile", "halo"), """
.bh-av--cloud .cloud-drift{animation:cloud-drift 4.6s ease-in-out infinite}
.bh-av--cloud .puff{animation:cloud-puff 3.2s ease-in-out infinite}
.bh-av--cloud .puff2{animation-delay:-1.1s}.bh-av--cloud .puff3{animation-delay:-2.2s}
.bh-av--cloud[data-state="happy"] .puff{animation-duration:.8s}
@keyframes cloud-drift{0%,100%{transform:translateX(-3px)}50%{transform:translateX(3px)}}
@keyframes cloud-puff{0%,100%{transform:scale(1)}50%{transform:scale(1.05)}}
""")
def draw_cloud():
    return ('<g class="anim cloud-drift">'
            '<circle class="p anim puff" cx="68" cy="122" r="30"/><circle class="p anim puff puff2" cx="134" cy="116" r="32"/>'
            '<circle class="p anim puff puff3" cx="100" cy="100" r="40"/>'
            '<rect class="p" x="42" y="118" width="116" height="46" rx="23"/>'
            '<rect class="s" x="56" y="148" width="88" height="12" rx="6" opacity=".7"/>'
            '<ellipse class="hl" cx="84" cy="76" rx="13" ry="7" transform="rotate(-25 84 76)"/>'
            '<ellipse class="hl" cx="56" cy="104" rx="6" ry="3.5" transform="rotate(-35 56 104)"/>'
            + bit_face(100, 122, 1.05) + bit_acc(100, 60, 62, 60) + '</g>')


# B8. Ghost ----------------------------------------------------------------
@bit("ghost", "Boo", "Ghost bot", {"p": "#F4F2FF", "s": "#CFC8FF", "a": "#FF6FB5", "bg": "#2B2742"},
     ("pill", "fang", "bow"), """
.bh-av--ghost .ghost-float{animation:ghost-float 2.8s ease-in-out infinite alternate}
.bh-av--ghost .ghost-arm{transform-origin:56px 118px;animation:ghost-wave 2.8s ease-in-out infinite alternate}
.bh-av--ghost[data-state="happy"] .ghost-arm{animation:ghost-wave .35s ease-in-out infinite alternate}
.bh-av--ghost .bh-shadow{animation:ghost-shadow 2.8s ease-in-out infinite alternate}
@keyframes ghost-float{from{transform:translateY(0)}to{transform:translateY(-7px)}}
@keyframes ghost-wave{from{transform:rotate(-6deg)}to{transform:rotate(14deg)}}
@keyframes ghost-shadow{from{transform:scaleX(1)}to{transform:scaleX(.82);opacity:.7}}
""")
def draw_ghost():
    body = ("M50 110 C 50 70, 72 44, 100 44 C 128 44, 150 70, 150 110 L150 162 Q 141 174 133 162 Q 125 150 117 162 "
            "Q 108 174 100 162 Q 92 150 83 162 Q 75 174 67 162 Q 58 150 50 162 Z")
    arm = '<g class="pv anim ghost-arm"><ellipse class="p" cx="47" cy="126" rx="8" ry="12" transform="rotate(28 47 126)"/></g>'
    return ('<g class="anim ghost-float">' + arm + mirror(arm)
            + '<path class="p" d="%s"/>' % body
            + '<path class="sh" d="M134 58 C 145 70, 150 88, 150 110 L150 162 Q 146 168 141 166 L 141 110 C 141 90, 139 72, 134 58 Z"/>'
            '<ellipse class="s" cx="100" cy="140" rx="24" ry="12" opacity=".5"/>'
            '<ellipse class="hl" cx="76" cy="66" rx="11" ry="6" transform="rotate(-35 76 66)"/>'
            + bit_face(100, 100, 1.1) + bit_acc(100, 44, 52, 56) + '</g>')


# B9. Bloom ----------------------------------------------------------------
@bit("bloom", "Bloom", "Flower bot", {"p": "#FF7EB6", "s": "#FFE27A", "a": "#6FD06B", "bg": "#FFEAF3", "face": "var(--s)"},
     ("round", "smile", "none"), """
.bh-av--bloom .petals{transform-origin:100px 106px;animation:bloom-spin 28s linear infinite}
.bh-av--bloom[data-state="happy"] .petals{animation-duration:3s}
.bh-av--bloom[data-state="thinking"] .petals{animation-duration:9s}
@keyframes bloom-spin{to{transform:rotate(360deg)}}
""")
def draw_bloom():
    import math
    petals_back, petals_front = "", ""
    for i in range(8):
        a = math.radians(i * 45 - 90)
        x, y = 100 + 43 * math.cos(a), 106 + 43 * math.sin(a)
        c = '<circle class="p" cx="%s" cy="%s" r="24"/>' % (n(x), n(y))
        if i % 2:
            petals_back += c + '<circle class="sh" cx="%s" cy="%s" r="24"/>' % (n(x), n(y))
        else:
            petals_front += c + '<circle class="hl" cx="%s" cy="%s" r="7" opacity=".5"/>' % (
                n(x - 6 * math.cos(a) - 4), n(y - 6 * math.sin(a) - 4))
    return ('<g class="pv anim petals">' + petals_back + petals_front + '</g>'
            + sell("s", 100, 106, 40, 40, k=4)
            + '<ellipse class="hl" cx="84" cy="84" rx="9" ry="5" transform="rotate(-35 84 84)"/>'
            + bit_face(100, 108, 1.0) + bit_acc(100, 40, 62, 66))


# B10. Gem -----------------------------------------------------------------
@bit("gem", "Glim", "Gem bot", {"p": "#19C3B1", "s": "#A6F2E8", "a": "#FF5E7E", "bg": "#E1F8F5"},
     ("cyclops", "none", "halo"), """
.bh-av--gem .gem-shine{animation:gem-shine 5s ease-in-out infinite}
.bh-av--gem .gem-glint{animation:bh-twinkle 2.6s ease-in-out infinite}
.bh-av--gem[data-state="happy"] .gem-shine{animation:gem-shine 1s ease-in-out infinite}
@keyframes gem-shine{0%,100%{transform:scaleX(1)}50%{transform:scaleX(.94)}}
""")
def draw_gem():
    d = "M94 44 Q100 38 106 44 L156 99 Q162 106 156 113 L106 168 Q100 174 94 168 L44 113 Q38 106 44 99 Z"
    return ('<g class="anim gem-shine">'
            '<path class="p" d="%s"/>' % d
            + '<path class="sh" d="M158.3 110 L103.6 170 L100 152 L140 106 Z"/>'
            '<path class="hl" style="fill-opacity:.24" d="M41.6 102 L96.4 42 L100 60 L60 106 Z"/>'
            '<path class="st-s" stroke-width="2.4" opacity=".6" d="M100 60 L140 106 L100 152 L60 106 Z M100 41 L100 60 M159 106 L140 106 M100 171 L100 152 M41 106 L60 106"/>'
            '<path class="w anim gem-glint" d="%s"/>' % star(76, 80, 6)
            + bit_face(100, 105, 1.0) + bit_acc(100, 40, 61, 66) + '</g>')


# ---------------------------------------------------------------------------
# Assembly
# ---------------------------------------------------------------------------
def vars_css(c):
    col = c["colors"]
    return (".bh-av--%s{--p:var(--av-primary,%s);--s:var(--av-secondary,%s);--a:var(--av-accent,%s);"
            "--bg:var(--av-bg,%s);--ink:var(--av-ink,#2A2238);--skin:var(--av-skin,%s)%s}") % (
        c["id"], col["p"], col["s"], col["a"], col["bg"], col.get("skin", "#F6CFB0"),
        (";--face:" + col["face"]) if "face" in col else "")


def compact(css):
    return "".join(line.strip() for line in css.strip().splitlines())


def build_svg(c):
    bits = c.get("family") == "bits"
    css = compact(SHARED_CSS) + (BITS_CSS if bits else "") + vars_css(c) + compact(c["css"])
    art = c["draw"]()
    extra = (' data-eyes="%s" data-mouth="%s" data-acc="%s" data-cheeks="on"' % (
        c["face"]["eyes"], c["face"]["mouth"], c["face"]["accessory"])) if bits else ""
    return (
        '<svg class="bh-avatar{fam} bh-av--{id}" data-character="{id}" data-state="idle" data-bg="on"{extra} '
        'viewBox="0 0 200 200" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="{name} the {role_l}">'
        '<title>{name} the {role_l}</title>'
        '<style>{css}</style>'
        '<circle class="bh-bg" cx="100" cy="100" r="96"/>'
        '<g class="bh-ring"><circle cx="100" cy="100" r="88"/><circle cx="100" cy="100" r="88"/></g>'
        '<ellipse class="bh-shadow" cx="100" cy="184" rx="44" ry="6"/>'
        '<g class="bh-rig pv"><g class="bh-body pv">{art}</g></g>'
        '{fx}'
        '</svg>'
    ).format(id=c["id"], name=c["name"], role_l=c["role"].lower(), css=css, art=art, fx=FX,
             fam=" bh-bits" if bits else "", extra=extra)


def main():
    os.makedirs(os.path.join(ROOT, "svg"), exist_ok=True)
    out = []
    for c in CHARACTERS:
        svg = build_svg(c)
        with open(os.path.join(ROOT, "svg", c["id"] + ".svg"), "w") as f:
            f.write(svg + "\n")
        out.append({"id": c["id"], "name": c["name"], "role": c["role"], "family": c.get("family", "classic"),
                    "face": c.get("face"),
                    "defaults": {"primary": c["colors"]["p"], "secondary": c["colors"]["s"],
                                 "accent": c["colors"]["a"], "background": c["colors"]["bg"]},
                    "svg": svg})

    with open(os.path.join(ROOT, "themes.json"), "w") as f:
        json.dump({"states": STATES, "themes": THEMES,
                   "faceOptions": {"eyes": EYE_STYLES, "mouth": MOUTH_STYLES, "accessory": ACCESSORIES},
                   "characters": [{k: v for k, v in o.items() if k != "svg"} for o in out]}, f, indent=2)

    tpl = open(os.path.join(ROOT, "tools", "avatars.template.js")).read()
    js = (tpl.replace("/*__THEMES__*/", json.dumps(THEMES, indent=2))
             .replace("/*__STATES__*/", json.dumps(STATES))
             .replace("/*__FACE__*/", json.dumps({"eyes": EYE_STYLES, "mouth": MOUTH_STYLES, "accessory": ACCESSORIES}))
             .replace("/*__CHARACTERS__*/", json.dumps(out, indent=1)))
    with open(os.path.join(ROOT, "avatars.js"), "w") as f:
        f.write(js)
    # SwiftUI wrapper
    def camel(k):
        return k
    cases = "\n".join("    case %s" % o["id"] for o in out)
    names = "\n".join('        case .%s: return "%s"' % (o["id"], o["name"]) for o in out)
    presets = []
    for key, t in THEMES.items():
        args = ", ".join('%s: "%s"' % (k, v) for k, v in t["colors"].items())
        doc = "Each character keeps its own palette." if key == "original" else t["name"] + " colorway."
        presets.append("    /// %s\n    public static let %s = AgentAvatarColors(%s)" % (doc, key, args))
    presets.append("\n    public static let presets: [(id: String, name: String, colors: AgentAvatarColors)] = [\n%s\n    ]" % ",\n".join(
        '        ("%s", "%s", .%s)' % (k, t["name"], k) for k, t in THEMES.items()))
    sw = open(os.path.join(ROOT, "tools", "AgentAvatarView.template.swift")).read()
    swift_case = {"none": None}
    def cases_for(values, none_name):
        return "\n".join(('    case %s = "none"' % none_name) if v == "none" else "    case %s" % v for v in values)
    isbit = "\n".join('        case .%s: return %s' % (o["id"], "true" if o["family"] == "bits" else "false") for o in out)
    sw = (sw.replace("/*__CASES__*/", cases).replace("/*__NAMES__*/", names).replace("/*__PRESETS__*/", "\n".join(presets))
            .replace("/*__STATECASES__*/", "    case " + ", ".join(STATES))
            .replace("/*__ISBIT__*/", isbit)
            .replace("/*__EYES__*/", cases_for(EYE_STYLES, "plain"))
            .replace("/*__MOUTHS__*/", cases_for(MOUTH_STYLES, "hidden"))
            .replace("/*__ACCS__*/", cases_for(ACCESSORIES, "bare")))
    os.makedirs(os.path.join(ROOT, "ios"), exist_ok=True)
    with open(os.path.join(ROOT, "ios", "AgentAvatarView.swift"), "w") as f:
        f.write(sw)
    # Preview playground (classic script: strip ESM exports)
    page = open(os.path.join(ROOT, "tools", "preview.template.html")).read()
    page = page.replace("/*__AVATARS__*/", js.replace("export const", "const").replace("export function", "function"))
    with open(os.path.join(ROOT, "preview.html"), "w") as f:
        f.write('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
                '<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">'
                '<style>body{margin:0}</style></head><body>\n' + page + '\n</body></html>\n')
    art = os.environ.get("BH_ARTIFACT_OUT")
    if art:
        with open(art, "w") as f:
            f.write(page)
    print("built", len(out), "avatars")


if __name__ == "__main__":
    main()
