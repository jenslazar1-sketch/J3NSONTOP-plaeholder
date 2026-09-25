import sys, importlib
from PIL import Image, ImageDraw, ImageFont
mod = importlib.import_module(sys.argv[1])
FONT = '/home/user/J3NSONTOP-plaeholder/assets/fonts/JetBrainsMono_700Bold.ttf'
f = ImageFont.truetype(FONT, 22)
cw = f.getbbox('M')[2]; lh = 28
lines = mod.CRANIUM + mod.JAW
drop = int(sys.argv[3]) if len(sys.argv) > 3 else 0
w = 44 * cw + 40; h = (len(lines) + 2) * lh + 40 + drop
img = Image.new('RGB', (w, h), (5, 5, 7)); d = ImageDraw.Draw(img)
for i, l in enumerate(mod.CRANIUM): d.text((20, 20 + i * lh), l, font=f, fill=(255, 22, 59), features=['-liga','-calt'])
for i, l in enumerate(mod.JAW): d.text((20, 20 + (len(mod.CRANIUM) + i) * lh + drop), l, font=f, fill=(255, 80, 100), features=['-liga','-calt'])
img.save(sys.argv[2])
