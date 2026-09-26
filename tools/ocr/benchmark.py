"""Synthetic screenshot OCR benchmark; no screen capture or private fixtures."""
import argparse
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time
from PIL import Image, ImageDraw, ImageFont
import worker

TEXT = [
    'Did you get home safely?',
    'Yes, I just got home!',
    'Thanks for letting me know.',
    "I'm sorry about the delay.",
    'Glad we had a chance to talk.',
    'I was thinking about our plans.',
    'The meeting starts at 9:30 AM.',
    'Please review the latest notes.',
    'Can we meet again next Tuesday?',
    'Sounds good, see you then!',
]


CODE = [
    'let cacheKey = "hippo_v1";',
    'if (retryCount <= 2) { return nil; }',
    'result.map { $0.id }.joined(separator: ",")',
    'GET /v1/events?limit=12&cursor=abc_123',
    'OCR punctuation: [a-z_]+ != nil; count += 1',
    'Hippocampus MCICaptureHelper cacheKey user_id',
    'Build succeeded. 12 tests passed (0 failures).',
    'Review changes before publishing the release.'
]


def render(size=14, corpus='chat'):
    image = Image.new('RGB', (2560, 1600), '#eeeef0')
    draw = ImageDraw.Draw(image)
    if corpus == 'code':
        image=Image.new('RGB',(2560,1600),'#202024')
        draw=ImageDraw.Draw(image)
        font=ImageFont.truetype('/System/Library/Fonts/Menlo.ttc',size)
        for index,text in enumerate(CODE):
            draw.text((80,100+index*50),text,font=font,fill='white')
        return image
    draw.rectangle((1750,200,2450,1450), fill='#080808')
    font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', size)
    for index, text in enumerate(TEXT):
        x = 1780 if index % 2 == 0 else 2040
        y = 350+index*85
        bounds=draw.textbbox((x,y),text,font=font)
        draw.rounded_rectangle((x-9,y-7,bounds[2]+9,bounds[3]+7),radius=10,
                               fill='#333333' if index%2==0 else '#258337')
        draw.text((x,y),text,font=font,fill='#ffffff')
    return image


def bitmap(image):
    rgba = image.convert('RGBA')
    data = rgba.tobytes('raw','BGRA')
    w,h=image.size
    return struct.pack('<2sIHHI',b'BM',54+len(data),0,0,54)+struct.pack('<IiiHHIIiiII',40,w,-h,1,32,0,len(data),0,0,0,0)+data


def distance(a,b):
    row=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        new=[i]
        for j,y in enumerate(b,1):
            new.append(min(new[-1]+1,row[j]+1,row[j-1]+(x!=y)))
        row=new
    return row[-1]


def measure(actual, expected=TEXT):
    # Per-source-line error measures recall without assuming detection order.
    # Report output count alongside it so hallucinated extra lines stay visible.
    return {'exact_lines': sum(t in actual for t in expected), 'expected_lines':len(expected),
            'line_character_errors':sum(min([distance(t,a) for a in actual]+[len(t)]) for t in expected),
            'expected_characters':sum(map(len,expected)), 'output_lines':len(actual)}


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--corpus',choices=['chat','code'],default='chat')
    p.add_argument('--worker',type=Path)
    p.add_argument('--vision',type=Path)
    args=p.parse_args()
    engine=None if args.worker else worker.load_engine(Path(__file__).parent/'models')
    import numpy as np
    rows=[]
    expected = TEXT if args.corpus == "chat" else CODE
    with tempfile.TemporaryDirectory(prefix='hippo-synthetic-ocr-') as temporary:
        for size in [10,12,16]:
            image=render(size,args.corpus)
            for resolution, sample in [('native',image),('old-1920',image.resize((1920,1200),Image.Resampling.LANCZOS))]:
                start=time.monotonic()
                if args.worker:
                    result=subprocess.run([str(args.worker.resolve())],input=bitmap(sample),capture_output=True,timeout=30,
                                          env={'PATH':'/usr/bin:/bin','PYTHONDONTWRITEBYTECODE':'1'})
                    result.check_returncode()
                    actual=[line['text'] for line in json.loads(result.stdout)['lines']]
                else:
                    r=engine(np.array(sample)[:,:,::-1].copy())
                    actual=[] if r.txts is None else list(r.txts)
                rows.append(dict(engine='paddle',font_pixels=size,resolution=resolution,seconds=round(time.monotonic()-start,3),**measure(actual,expected)))
                if args.vision:
                    path=Path(temporary)/'synthetic.png'
                    sample.save(path)
                    out=subprocess.run([str(args.vision),str(path)],capture_output=True,check=True,env={'PATH':'/usr/bin:/bin'})
                    r=json.loads(out.stdout)
                    rows.append(dict(engine='vision-production',font_pixels=size,resolution=resolution,seconds=round(r['seconds'],3),**measure([line['text'] for line in r['lines']],expected)))
    print(json.dumps(rows,indent=2))


if __name__=='__main__':
    main()
