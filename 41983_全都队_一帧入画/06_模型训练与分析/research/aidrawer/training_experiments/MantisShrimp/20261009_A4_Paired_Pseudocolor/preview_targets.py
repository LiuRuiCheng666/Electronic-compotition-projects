"""Preview deterministic targets, without instantiating/training a network."""
import argparse
import json
from pathlib import Path
import torch
from PIL import Image, ImageDraw
from torchvision.transforms import functional as TF
from target import load_rules, pseudocolor


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input-dir', type=Path, default=Path('D:/aidrawer/data/student_eval_external'))
    ap.add_argument('--output', type=Path, default=Path('D:/aidrawer/output/MantisShrimp/20261009_A4_Paired_Pseudocolor/target_preview_v1'))
    ap.add_argument('--rules', type=Path, default=Path(__file__).with_name('rules.json'))
    ap.add_argument('--count', type=int, default=6)
    ap.add_argument('--reference', type=Path, help='Optional split screenshot: left scene is transformed; right scene is displayed as reference only')
    a = ap.parse_args()
    paths = sorted(p for p in a.input_dir.rglob('*') if p.suffix.lower() in {'.png', '.jpg', '.jpeg'})[:a.count]
    if not paths or a.count < 1:
        raise ValueError('Need preview input images and a positive count')
    if a.output.exists():
        raise RuntimeError('Refusing overwrite; select a new --output')
    a.output.mkdir(parents=True)
    rules = load_rules(a.rules)
    panels = []
    for i, path in enumerate(paths):
        with Image.open(path) as im:
            original = im.convert('RGB').resize((640, 480), Image.Resampling.BICUBIC)
        y = pseudocolor(TF.to_tensor(original)[None], rules)
        target = TF.to_pil_image(y[0])
        target.save(a.output / f'target_{i:02d}.png')
        panel = Image.new('RGB', (640, 266), 'white')
        draw = ImageDraw.Draw(panel)
        for c, (label, image) in enumerate([('Input', original), ('Rule target (NOT A4 output)', target)]):
            panel.paste(image.resize((320, 240)), (c * 320, 26))
            draw.text((c * 320 + 5, 5), label, fill='black')
        panel.save(a.output / f'panel_{i:02d}.jpg', quality=95)
        panels.append(panel)
    sheet = Image.new('RGB', (1280, 266 * ((len(panels) + 1) // 2)), 'white')
    for i, panel in enumerate(panels):
        sheet.paste(panel, ((i % 2) * 640, (i // 2) * 266))
    sheet.save(a.output / 'contact_sheet.jpg', quality=95)
    if a.reference:
        with Image.open(a.reference) as im:
            w, h = im.size
            scene = im.convert('RGB').crop((0, 0, int(w * .49), int(h * .778))).resize((640, 480))
            reference = im.convert('RGB').crop((int(w * .508), 0, w, int(h * .778))).resize((640, 480))
        target = TF.to_pil_image(pseudocolor(TF.to_tensor(scene)[None], rules)[0])
        panel = Image.new('RGB', (1920, 506), 'white')
        draw = ImageDraw.Draw(panel)
        for i, (label, image) in enumerate([('Reference left input', scene), ('Our rule target (NOT trained)', target), ('Desired right reference (different frame)', reference)]):
            panel.paste(image, (640 * i, 26))
            draw.text((640 * i + 5, 5), label, fill='black')
        panel.save(a.output / 'reference_comparison.jpg', quality=95)
    (a.output / 'preview_manifest.json').write_text(json.dumps({'rules': rules, 'inputs': [str(p) for p in paths],
                                                              'reference_only': str(a.reference) if a.reference else None}, indent=2), encoding='utf-8')
    print(a.output)


if __name__ == '__main__':
    main()
