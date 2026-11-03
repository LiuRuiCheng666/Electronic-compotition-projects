"""Deterministic per-image rule teacher; never runs in deployed A4 inference."""
import json
from pathlib import Path
import torch
import torch.nn.functional as F


def load_rules(path=None):
    rules = json.loads(Path(path or Path(__file__).with_name('rules.json')).read_text(encoding='utf-8'))
    knots = rules['luma_knots']
    if knots[0] != 0 or knots[-1] != 1 or any(a >= b for a, b in zip(knots, knots[1:])):
        raise ValueError('Luma knots must increase from 0 to 1')
    if len(knots) != len(rules['palette']):
        raise ValueError('Palette and knots differ')
    for rgb in rules['palette'] + [rules[k] for k in ['blue_rgb', 'yellow_rgb', 'red_rgb', 'green_rgb']]:
        if len(rgb) != 3 or any(not 0 <= v <= 1 for v in rgb):
            raise ValueError('Invalid RGB palette')
    if not 0 <= rules['chroma_start'] < rules['chroma_full'] <= 1:
        raise ValueError('Invalid chroma range')
    if not 0 <= rules['chroma_mix'] <= 1 or not 0 <= rules['brightness_floor'] <= 1:
        raise ValueError('Invalid mix or brightness')
    if rules['detail_gain'] < 0 or not 0 <= rules['detail_limit'] <= .25:
        raise ValueError('Invalid detail enhancement')
    return rules


def smoothstep(z):
    z = z.clamp(0, 1)
    return z * z * (3 - 2 * z)


@torch.no_grad()
def pseudocolor(x, rules):
    x = x.float().clamp(0, 1)
    r, g, b = x.split(1, 1)
    lum = .2126 * r + .7152 * g + .0722 * b
    local = F.avg_pool2d(F.pad(lum, (2, 2, 2, 2), mode='reflect'), 5, stride=1)
    detail = (rules['detail_gain'] * (lum - local)).clamp(-rules['detail_limit'], rules['detail_limit'])
    coordinate = (lum + detail).clamp(0, 1)
    palette = x.new_tensor(rules['palette'])
    knots = rules['luma_knots']
    # Continuous interpolation with zero slope at every knot; no hard bins.
    result = palette[0].view(1, 3, 1, 1).expand_as(x).clone()
    for i in range(len(knots) - 1):
        t = smoothstep((coordinate - knots[i]) / (knots[i + 1] - knots[i]))
        result += t * (palette[i + 1] - palette[i]).view(1, 3, 1, 1)
    # Continuous RGB opponent weights, independent of scene-wide statistics.
    yellow = (torch.minimum(r, g) - b).clamp_min(0)
    blue_cyan = (b - torch.maximum(r, g)).clamp_min(0) + (torch.minimum(g, b) - r).clamp_min(0)
    red_magenta = (r - torch.maximum(g, b)).clamp_min(0) + (torch.minimum(r, b) - g).clamp_min(0)
    green = (g - torch.maximum(r, b)).clamp_min(0)
    weights = torch.cat([blue_cyan, yellow, red_magenta, green], 1)
    anchors = x.new_tensor([rules[k] for k in ['blue_rgb', 'yellow_rgb', 'red_rgb', 'green_rgb']])
    colored = torch.einsum('bkhw,kc->bchw', weights, anchors) / weights.sum(1, keepdim=True).clamp_min(1e-6)
    chroma = x.amax(1, keepdim=True) - x.amin(1, keepdim=True)
    mix = rules['chroma_mix'] * smoothstep((chroma - rules['chroma_start']) /
                                          (rules['chroma_full'] - rules['chroma_start']))
    colored *= rules['brightness_floor'] + (1 - rules['brightness_floor']) * lum
    return ((1 - mix) * result + mix * colored).clamp(0, 1)
