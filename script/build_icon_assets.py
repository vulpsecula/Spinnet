# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==13.0.0", "resvg-py==0.5.0"]
# ///
"""Rebuild editable icon artwork and the monochrome macOS PDF template.

The paths use the supplied reference's coordinates; all AppIcon layers share
the same viewBox. No raster image is embedded in the SVGs or PDF.
Run with `uv run --script script/build_icon_assets.py`. This overwrites the
generated artwork; retain manual Icon Composer edits before regenerating.
"""
from io import BytesIO
import hashlib
import json
import math
from pathlib import Path

from PIL import Image, ImageDraw
import resvg_py

ROOT = Path(__file__).resolve().parents[1]
DESIGN = ROOT / "Resources/IconDesign"
PROJECT = ROOT / "Resources/AppIcon.icon"
PREVIEWS = ROOT / "dist/IconPreviews"
# This model is traced from the reference, including its asymmetric curves
# and individually rounded sector corners. Do not replace it with pie slices.
MODEL = json.loads((DESIGN / "AppIconGeometry.json").read_text())

def linear_gradient(name, model):
    first, last = model["from"], model["to"]
    stops = "".join(
        f'<stop offset="{stop["offset"]:.6f}" '
        f'stop-color="rgb({",".join(str(v) for v in stop["rgb"])})"/>'
        for stop in model["stops"]
    )
    result = (f'<linearGradient id="{name}" x1="{first[0]:.6f}" y1="{first[1]:.6f}" '
              f'x2="{last[0]:.6f}" y2="{last[1]:.6f}" '
              f'gradientUnits="userSpaceOnUse">{stops}</linearGradient>')
    for index, overlay in enumerate(model.get("overlays", [])):
        matrix = " ".join(f"{value:.6f}" for value in overlay["matrix"])
        color = ",".join(str(value) for value in overlay["rgb"])
        radial_stops = "".join(
            f'<stop offset="{step / 32:.6f}" stop-color="rgb({color})" '
            f'stop-opacity="{overlay["strength"] * math.exp(-.5 * (3.5 * step / 32) ** 2):.6f}"/>'
            for step in range(33)
        )
        result += (f'<radialGradient id="{name}-light-{index}" cx="0" cy="0" r="1" '
                   f'gradientUnits="userSpaceOnUse" gradientTransform="matrix({matrix})">'
                   f'{radial_stops}</radialGradient>')
    return result

DEFS = "\n".join(linear_gradient(name, gradient) for name, gradient in MODEL["gradients"].items())

tail = MODEL.get("ribbon_tail_fade")
if tail:
    tail_stops = "".join(
        f'<stop offset="{stop["offset"]:.6f}" stop-color="#fff" '
        f'stop-opacity="{stop["opacity"]:.6f}"/>' for stop in tail["stops"]
    )
    DEFS += (f'<linearGradient id="ribbon-tail-opacity" x1="0" y1="{tail["from_y"]:.6f}" '
             f'x2="0" y2="{tail["to_y"]:.6f}" gradientUnits="userSpaceOnUse">'
             f'{tail_stops}</linearGradient>'
             '<mask id="ribbon-tail-mask" maskUnits="userSpaceOnUse" '
             'maskContentUnits="userSpaceOnUse" x="0" y="0" width="1254" height="1254">'
             '<rect width="1254" height="1254" fill="url(#ribbon-tail-opacity)"/></mask>')

def path(name, fill):
    data = MODEL["paths"][name]
    if isinstance(data, dict):
        geometry = (f'<circle cx="{data["cx"]:.6f}" cy="{data["cy"]:.6f}" '
                    f'r="{data["r"]:.6f}"/>')
    else:
        geometry = f'<path d="{data}"/>'
    if not MODEL["gradients"][fill].get("overlays"):
        return geometry.replace('/>', f' id="{name}" fill="url(#{fill})"/>')
    result = (f'<g id="{name}" clip-path="url(#outline-{name})">'
              f'<defs><clipPath id="outline-{name}" clipPathUnits="userSpaceOnUse">'
              f'{geometry}</clipPath></defs>{material_rect(fill)}</g>')
    if name == "s-ribbon" and tail:
        result = f'<g mask="url(#ribbon-tail-mask)">{result}</g>'
    return result

def material_rect(fill):
    materials = [fill] + [f"{fill}-light-{index}" for index, _ in
                          enumerate(MODEL["gradients"][fill].get("overlays", []))]
    return "".join(f'<rect width="1254" height="1254" fill="url(#{name})"/>' for name in materials)

FAN = "\n".join(path(name, fill) for name, fill in [
    ("upper-left", "fan-left"), ("upper", "fan-top"), ("right", "fan-right"),
    ("lower-right", "fan-lower"), ("bottom", "fan-bottom"),
])
BLUE = path("selected-blue-wedge", "selected")
# The ribbon owns the shared boundary; the lower face sits behind it.
RIBBON = path("s-lower-face", "face") + "\n" + path("s-ribbon", "ribbon")

# A painted radial shadow reproduces the reference without depending on
# renderer-specific blur filters or enabling Liquid Glass on the artwork.
shadow = MODEL["hub_shadow"]
shadow_color = ",".join(str(value) for value in shadow.get("rgb", [0, 0, 0]))
shadow_stops = "".join(
    f'<stop offset="{stop["offset"]:.6f}" stop-color="rgb({shadow_color})" stop-opacity="{stop["opacity"]:.6f}"/>'
    for stop in shadow["stops"]
)
DEFS += (f'<radialGradient id="hub-shadow" cx="{shadow["cx"]:.6f}" cy="{shadow["cy"]:.6f}" '
         f'r="{shadow["radius"]:.6f}" gradientUnits="userSpaceOnUse">{shadow_stops}</radialGradient>')
HUB = (f'<circle cx="{shadow["cx"]:.6f}" cy="{shadow["cy"]:.6f}" '
       f'r="{shadow["radius"]:.6f}" fill="url(#hub-shadow)"/>\n'
       + path("hub-disc", "hub") + "\n" + path("hub-dot", "dot"))
LAYERS = [("01 Fan", FAN), ("02 Selected Wedge", BLUE), ("03 S Ribbon", RIBBON), ("04 Center Hub", HUB)]

def svg(body, size=1024, viewbox='98 100 1060 1060'):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="{size}" height="{size}" viewBox="{viewbox}">
<title>Spinnet</title><defs>{DEFS}</defs>{body}</svg>'''

def color(hex_color):
    return 'extended-srgb:' + ','.join(f'{int(hex_color[i:i+2],16)/255:.5f}' for i in (0,2,4)) + ',1.00000'


# Menu-bar template: the prototype's split annulus, inverted sector and dot.
# Cubic paths are shared verbatim by the SVG and resolution-independent PDF.
LEFT = [
    ('M', 102, 51), ('C', 99, 46, 94, 46, 90, 49),
    ('C', 41, 82, 12, 135, 12, 194), ('C', 12, 285, 78, 362, 168, 374),
    ('C', 177, 376, 184, 371, 184, 362), ('L', 184, 313),
    ('C', 184, 306, 180, 302, 174, 301), ('C', 121, 292, 82, 247, 82, 194),
    ('C', 82, 158, 99, 126, 127, 106), ('C', 132, 102, 133, 97, 130, 91), ('Z',),
]
RIGHT = [(c[0], *[384-v if i%2==0 else v for i,v in enumerate(c[1:])]) for c in LEFT]
WEDGE = [('M',130,12),('C',169,-2,215,-2,254,12),('C',263,15,265,22,260,31),('L',204,130),('C',199,139,185,139,180,130),('L',124,31),('C',119,22,121,15,130,12),('Z',)]
K = .5522847498
DOT = [('M',218,190),('C',218,190+26*K,192+26*K,216,192,216),('C',192-26*K,216,166,190+26*K,166,190),('C',166,190-26*K,192-26*K,164,192,164),('C',192+26*K,164,218,190-26*K,218,190),('Z',)]

def path_data(commands):
    return ' '.join(c[0]+' '+' '.join(f'{v:.5f}' for v in c[1:]) for c in commands)

def template_pdf(shapes):
    # PDF coordinates point up. Artwork has a 1pt inset on an 18pt canvas.
    content = 'q\n0.041666667 0 0 -0.041666667 1 17 cm\n0 g\n'
    ops={'M':'m','L':'l','C':'c','Z':'h'}
    for shape in shapes:
        content += '\n'.join(' '.join(f'{v:.5f}' for v in c[1:])+' '+ops[c[0]] for c in shape)+'\nf\n'
    content+='Q\n'
    stream=content.encode('ascii')
    objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 18 18] /Resources << >> /Contents 4 0 R >>',f'<< /Length {len(stream)} >>\nstream\n'.encode()+stream+b'endstream']
    result=bytearray(b'%PDF-1.4\n'); offsets=[0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(result)); result+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
    xref=len(result); result+=f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]: result+=f'{offset:010d} 00000 n \n'.encode()
    result+=f'trailer\n<< /Size {len(objects)+1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode()
    return result

def main():
    reference = DESIGN / MODEL["reference"]
    if hashlib.sha256(reference.read_bytes()).hexdigest() != MODEL["reference_sha256"]:
        raise ValueError("The icon reference changed; retrace the model before rebuilding.")
    DESIGN.mkdir(parents=True,exist_ok=True); (PROJECT/'Assets').mkdir(parents=True,exist_ok=True); PREVIEWS.mkdir(parents=True,exist_ok=True)
    groups=[]; body=''
    for name,content in LAYERS:
        filename=name.replace(' ','_')+'.svg'
        (PROJECT/'Assets'/filename).write_text(svg(content))
        body+=f'<g id="{filename[:-4]}" inkscape:groupmode="layer" inkscape:label="{name}">{content}</g>'
    # Array order is front-to-back; each graphic appears exactly once.
    groups.append({'name':'Spinnet','layers':[{'name':name,'image-name':name.replace(' ','_')+'.svg','glass':False} for name,_ in reversed(LAYERS)],'shadow':{'kind':'neutral','opacity':0},'translucency':{'enabled':False,'value':0}})
    # Preserve the original multi-stop background in Default. Other system
    # appearances keep their native background, rather than tinting a full
    # opaque square along with the foreground silhouette.
    background = material_rect("background")
    (PROJECT / 'Assets/00_Background.svg').write_text(svg(background))
    groups.append({
        'name': 'Background',
        'layers': [{'name': '00 Background', 'image-name': '00_Background.svg', 'glass': False}],
        'hidden-specializations': [
            {'appearance': 'dark', 'value': True},
            {'appearance': 'tinted', 'value': True},
        ],
        'shadow': {'kind': 'neutral', 'opacity': 0},
        'translucency': {'enabled': False, 'value': 0},
    })
    document={'fill':{'linear-gradient':[color('dceaff'),color('72acfc')],'orientation':{'start':{'x':0,'y':0},'stop':{'x':1,'y':1}}},'groups':groups,'supported-platforms':{'squares':'shared'}}
    (PROJECT/'icon.json').write_text(json.dumps(document,indent=2)+'\n')
    composition=svg('<g id="Background" inkscape:groupmode="layer" inkscape:label="Background">'+background+'</g>'+body)
    (DESIGN/'AppIcon.svg').write_text(composition)
    (PREVIEWS/'AppIcon-unmasked.png').write_bytes(resvg_py.svg_to_bytes(svg_string=composition,skip_system_fonts=True))
    shapes=[LEFT,RIGHT,WEDGE,DOT]
    menu='<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="-24 -24 432 432"><title>Spinnet Status Item</title>'+''.join(f'<path d="{path_data(s)}" fill="#000"/>' for s in shapes)+'</svg>'
    (DESIGN/'StatusItem.svg').write_text(menu)
    (ROOT/'Sources/SpinnetHost/Resources/StatusItemTemplate.pdf').write_bytes(template_pdf(shapes))
    # Preview at actual 1x/2x and enlarged, against light and dark backgrounds.
    canvas=Image.new('RGB',(640,200),'#f4f5f7'); draw=ImageDraw.Draw(canvas)
    for x,bg,fg in [(0,'#f4f5f7','#151515'),(320,'#242424','#fafafa')]:
        draw.rectangle((x,0,x+320,200),fill=bg)
        for i,size in enumerate((18,36,96)):
            raster=resvg_py.svg_to_bytes(svg_string=menu.replace('#000',fg),width=size,height=size,skip_system_fonts=True)
            im=Image.open(BytesIO(raster)).convert('RGBA'); canvas.paste(im,(x+24+i*90,50),im)
            draw.text((x+24+i*90,160),f'{size}px',fill=fg)
    canvas.save(PREVIEWS/'StatusItem.png')
    print('Generated reference-traced SVGs, AppIcon.icon and the 18pt PDF template.')

if __name__=='__main__': main()
