#!/usr/bin/env python3
"""
Генератор иллюстраций для демо-студий (tenants/<slug>/images): главное фото, логотип, три карточки работ.
Это рисунки-заглушки в фирменном цвете студии, а не фотографии: настоящие фото владелец загрузит в кабинете.
Запуск: python3 scripts/gen-demo-art.py
"""
import json, math, os, random

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CAR = ("M150,640 C158,598 200,578 280,568 L420,538 C500,480 570,452 668,449 C772,446 838,470 902,515 L1000,536 "
       "C1052,546 1086,572 1090,610 L1092,640 C1092,654 1082,660 1068,660 L1012,660 A78,78 0 0 0 856,660 L432,660 "
       "A78,78 0 0 0 276,660 L176,660 C160,660 150,654 150,640 Z")
GLASS = "M448,540 C520,490 580,468 668,466 C752,464 808,482 856,516 L842,532 L466,540 Z"
ROOF = "M290,566 L420,538 C500,480 570,452 668,449 C772,446 838,470 902,515 L1000,536"


def mix(a, b, t):
    a = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02X}" for x, y in zip(a, b))


def defs(acc, body):
    return f"""<defs>
<radialGradient id="g" cx="50%" cy="38%" r="75%"><stop offset="0" stop-color="{mix('#050607', acc, .28)}"/><stop offset=".55" stop-color="{mix('#050607', acc, .07)}"/><stop offset="1" stop-color="#030405"/></radialGradient>
<linearGradient id="floor" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{mix('#050607', acc, .1)}"/><stop offset="1" stop-color="#020304"/></linearGradient>
<linearGradient id="body" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{mix(body, '#FFFFFF', .18)}"/><stop offset=".35" stop-color="{body}"/><stop offset=".7" stop-color="{mix(body, '#000000', .7)}"/><stop offset="1" stop-color="{mix(body, '#000000', .45)}"/></linearGradient>
<linearGradient id="hl" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{acc}" stop-opacity="0"/><stop offset=".45" stop-color="{mix(acc, '#FFFFFF', .55)}"/><stop offset=".7" stop-color="{acc}"/><stop offset="1" stop-color="{acc}" stop-opacity="0"/></linearGradient>
<linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{mix('#3A4E6E', acc, .25)}"/><stop offset=".5" stop-color="#0B111A"/><stop offset="1" stop-color="#1A2433"/></linearGradient>
<filter id="blur" x="-20%" y="-200%" width="140%" height="500%"><feGaussianBlur stdDeviation="8"/></filter>
<filter id="blur2"><feGaussianBlur stdDeviation="22"/></filter>
</defs>"""


def car(acc):
    wheel = lambda x: (f'<g><circle cx="{x}" cy="660" r="66" fill="#06080B" stroke="#1E2632" stroke-width="6"/>'
                       f'<circle cx="{x}" cy="660" r="42" fill="#11161D" stroke="#3B4757" stroke-width="3"/>'
                       f'<circle cx="{x}" cy="660" r="10" fill="{acc}"/></g>')
    return f"""<g transform="translate(0,40)">
<path d="{CAR}" fill="url(#body)" stroke="#2A3443" stroke-width="2"/>
<path d="{GLASS}" fill="url(#glass)" stroke="#3B4A60" stroke-width="2"/>
<path d="M640,467 L652,538" stroke="#05070A" stroke-width="10"/>
<path d="{ROOF}" fill="none" stroke="url(#hl)" stroke-width="4" stroke-linecap="round"/>
<path d="M170,612 C400,600 800,598 1086,604" fill="none" stroke="{acc}" stroke-opacity=".35" stroke-width="2"/>
<rect x="1048" y="566" width="40" height="14" rx="7" fill="#DCE9FF" filter="url(#blur)" opacity=".9"/>
<rect x="1052" y="568" width="32" height="8" rx="4" fill="#fff"/>
<rect x="152" y="582" width="30" height="10" rx="5" fill="#FF4A4A" opacity=".85"/>
{wheel(354)}{wheel(934)}
</g>"""


def hero(s):
    acc, body, scene = s["accent"], s["body"], s["scene"]
    rnd = random.Random(s["slug"])
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 1000" preserveAspectRatio="xMidYMid slice">', defs(acc, body),
             '<rect width="1200" height="1000" fill="url(#g)"/>']
    if scene == "studio":  # детейлинг: световые панели над постом
        for i, (x, w, y) in enumerate([(250, 700, 150), (330, 540, 215), (420, 360, 268)]):
            c = mix(acc, "#FFFFFF", .75 - i * .25)
            parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="10" rx="5" fill="{c}" filter="url(#blur)"/>'
                         f'<rect x="{x}" y="{y}" width="{w}" height="5" rx="2.5" fill="{mix(c, "#FFFFFF", .6)}"/>')
    elif scene == "hex":  # детейлинг: шестиугольные лампы
        for row in range(3):
            for col in range(7):
                cx, cy = 210 + col * 130 + (65 if row % 2 else 0), 130 + row * 75
                pts = " ".join(f"{cx + 34 * math.cos(math.radians(a)):.0f},{cy + 34 * math.sin(math.radians(a)):.0f}" for a in range(0, 360, 60))
                parts.append(f'<polygon points="{pts}" fill="none" stroke="{mix(acc, "#FFFFFF", .7)}" stroke-width="5" opacity=".9"/>')
        parts.append(f'<rect x="150" y="80" width="900" height="260" fill="{acc}" opacity=".08" filter="url(#blur2)"/>')
    elif scene == "wash":  # мойка: арка, струи и пена
        parts.append(f'<path d="M140,690 L140,230 Q600,90 1060,230 L1060,690" fill="none" stroke="{mix(acc, "#FFFFFF", .3)}" stroke-width="14" opacity=".55"/>')
        for i in range(9):
            x = 230 + i * 92
            parts.append(f'<path d="M{x},250 Q{x + rnd.randint(-30, 30)},420 {x + rnd.randint(-40, 40)},560" fill="none" stroke="{mix(acc, "#FFFFFF", .6)}" stroke-width="3" opacity=".35" filter="url(#blur)"/>')
    parts.append('<rect y="640" width="1200" height="360" fill="url(#floor)"/>')
    parts.append(f'<ellipse cx="610" cy="700" rx="470" ry="40" fill="{acc}" opacity=".2" filter="url(#blur2)"/>')
    parts.append(car(acc))
    if scene == "wash":
        for _ in range(38):
            x, y, r = rnd.randint(170, 1080), rnd.randint(560, 700), rnd.randint(6, 20)
            parts.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#FFFFFF" opacity="{rnd.uniform(.25, .7):.2f}"/>')
    parts.append(f'<g opacity=".18" transform="translate(0,1400) scale(1,-1)"><path d="{CAR.split(" L1012")[0]} L176,660 C160,660 150,654 150,640 Z" fill="{acc}" filter="url(#blur2)"/></g>')
    parts.append("</svg>")
    return "\n".join(parts)


def logo(s):
    acc, mark = s["accent"], s["mark"]
    size = 210 if len(mark) == 1 else 150 if len(mark) == 2 else 112
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><rect width="512" height="512" rx="112" fill="#0B0E12"/>'
            f'<circle cx="256" cy="256" r="196" fill="none" stroke="{acc}" stroke-width="14"/>'
            f'<text x="256" y="258" text-anchor="middle" dominant-baseline="central" font-family="Arial Black, Arial, sans-serif" font-weight="900" font-size="{size}" fill="#FFFFFF" letter-spacing="-4">{mark}</text></svg>')


def work(s, kind):
    acc, rnd = s["accent"], random.Random(s["slug"] + kind)
    bg = mix("#0B0E12", acc, .12)
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 600"><rect width="800" height="600" fill="{bg}"/>']
    if kind == "polish":  # отражение ламп в отполированной панели
        p.append(f'<path d="M0,420 C200,300 600,260 800,330 L800,600 L0,600 Z" fill="{mix(s["body"], "#000000", .3)}"/>')
        for i in range(4):
            y = 360 - i * 18
            p.append(f'<path d="M{80 + i * 40},{y + 60} C300,{y - 40} 520,{y - 60} {760 - i * 30},{y - 10}" fill="none" stroke="#FFFFFF" stroke-opacity="{.75 - i * .15:.2f}" stroke-width="{10 - i * 2}" stroke-linecap="round"/>')
        p.append(f'<circle cx="610" cy="250" r="90" fill="{acc}" opacity=".18"/>')
    elif kind == "interior":  # сиденье после химчистки
        p.append(f'<path d="M330,120 C300,120 290,140 290,170 L300,380 C302,410 320,420 350,420 L470,420 C500,420 512,404 510,380 L520,170 C520,140 506,120 476,120 Z" fill="{mix("#2A2F38", acc, .15)}"/>')
        p.append('<path d="M250,420 L560,420 C590,420 600,440 596,470 L586,520 L240,520 L232,470 C228,440 236,420 250,420 Z" fill="#1E232B"/>')
        for x in (360, 405, 450):
            p.append(f'<path d="M{x},140 L{x},400" stroke="{acc}" stroke-opacity=".4" stroke-width="3"/>')
        for _ in range(14):
            x, y = rnd.randint(120, 700), rnd.randint(80, 520)
            p.append(f'<path d="M{x},{y - 10} L{x + 3},{y - 3} L{x + 10},{y} L{x + 3},{y + 3} L{x},{y + 10} L{x - 3},{y + 3} L{x - 10},{y} L{x - 3},{y - 3} Z" fill="#FFFFFF" opacity=".7"/>')
    elif kind == "foam":  # пена на кузове
        p.append(f'<path d="M0,380 C180,300 620,280 800,340 L800,600 L0,600 Z" fill="{mix(s["body"], "#000000", .2)}"/>')
        for _ in range(110):
            x, y, r = rnd.randint(0, 800), rnd.randint(250, 520), rnd.randint(10, 46)
            p.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="#FFFFFF" opacity="{rnd.uniform(.35, .9):.2f}"/>')
    elif kind == "wheel":  # чистый диск
        p.append(f'<circle cx="400" cy="300" r="230" fill="#07090C" stroke="#232A33" stroke-width="18"/><circle cx="400" cy="300" r="150" fill="{mix("#3A414C", acc, .1)}"/>')
        for a in range(0, 360, 72):
            x, y = 400 + 140 * math.cos(math.radians(a)), 300 + 140 * math.sin(math.radians(a))
            p.append(f'<path d="M400,300 L{x:.0f},{y:.0f}" stroke="#11151B" stroke-width="40" stroke-linecap="round"/>')
        p.append(f'<circle cx="400" cy="300" r="34" fill="{acc}"/>')
    elif kind == "film":  # плёнка на фаре
        p.append(f'<path d="M120,330 C200,200 560,170 690,250 C720,270 720,330 690,360 C560,450 220,450 140,400 Z" fill="#0E131A" stroke="{mix(acc, "#FFFFFF", .4)}" stroke-width="6"/>')
        p.append(f'<path d="M200,320 C300,240 520,230 620,280" stroke="#FFFFFF" stroke-opacity=".75" stroke-width="10" fill="none" stroke-linecap="round"/>')
        p.append(f'<path d="M150,290 L700,230 L700,420 L150,470 Z" fill="{acc}" opacity=".12"/>')
    p.append("</svg>")
    return "".join(p)


def main():
    cfg = json.load(open(os.path.join(ROOT, "scripts", "demo-studios.json"), encoding="utf-8"))
    for s in cfg:
        d = os.path.join(ROOT, "tenants", s["slug"], "images")
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "hero.svg"), "w").write(hero(s))
        open(os.path.join(d, "logo.svg"), "w").write(logo(s))
        for i, kind in enumerate(s["works"], 1):
            open(os.path.join(d, f"work-{i}.svg"), "w").write(work(s, kind))
        print("✓", s["slug"])


if __name__ == "__main__":
    main()
