"""Palette area reporting only: never imported into training losses."""
import torch
PALETTE_SIZE=8
MIN_AREA=.05
COLOR_RADIUS=.15  # Euclidean distance in RGB [0,1], not a perceptual Delta-E.

def sampled_rgb(x,count=4096):
    z=x.float().flatten(2).transpose(1,2)
    idx=torch.linspace(0,z.shape[1]-1,min(count,z.shape[1]),device=z.device).long()
    return z[:,idx]

@torch.no_grad()
def teacher_palette(rgb):
    # Deterministic farthest-first seeds, followed by Lloyd k-means on teacher only.
    centers=[rgb.mean(0)]
    for _ in range(PALETTE_SIZE-1):
        d=torch.cdist(rgb,torch.stack(centers),compute_mode='donot_use_mm_for_euclid_dist').min(1).values
        candidate=rgb[d.argmax()]
        if d.max()<.08:break  # Do not invent eight distinct colors in a neutral image.
        centers.append(candidate)
    c=torch.stack(centers)
    for _ in range(12):
        ix=torch.cdist(rgb,c,compute_mode='donot_use_mm_for_euclid_dist').argmin(1)
        c=torch.stack([rgb[ix==k].mean(0) if (ix==k).any() else c[k] for k in range(len(c))])
    # Merge redundant representatives so one color is not counted repeatedly.
    kept=[]
    for center in c:
        if not kept or torch.cdist(center[None],torch.stack(kept)).min()>=.08:kept.append(center)
    c=torch.stack(kept)
    ix=torch.cdist(rgb,c,compute_mode='donot_use_mm_for_euclid_dist').argmin(1)
    area=torch.bincount(ix,minlength=len(c)).float()/len(rgb)
    return c,area

@torch.no_grad()
def palette_report(y,teacher):
    centers,area=teacher_palette(sampled_rgb(teacher)[0])
    nearest=torch.zeros(len(centers),device=y.device);valid=nearest.clone();distance_sum=nearest.clone()
    pixels=y.float().flatten(2).transpose(1,2)[0]
    for chunk in pixels.split(32768):
        d=torch.cdist(chunk,centers,compute_mode='donot_use_mm_for_euclid_dist')
        distance,ix=d.min(1)
        nearest+=torch.bincount(ix,minlength=len(centers))
        valid+=torch.bincount(ix[distance<=COLOR_RADIUS],minlength=len(centers))
        distance_sum.scatter_add_(0,ix,distance)
    rows=[]
    for k,c in enumerate(centers):
        share=(valid[k]/len(pixels)).item()
        rows.append({'rgb_u8':(c*255).round().int().tolist(),'teacher_sample_area':area[k].item(),
                     'nearest_area':(nearest[k]/len(pixels)).item(),
                     'distance_qualified_area':share,'mean_nearest_rgb_distance':(distance_sum[k]/nearest[k].clamp_min(1)).item(),
                     'passes_5_percent':share+1e-8>=MIN_AREA})
    return {'palette_count':len(centers),'rgb_distance_radius':COLOR_RADIUS,'all_colors_pass':all(r['passes_5_percent'] for r in rows),
            'uncovered_pixel_fraction':(1-valid.sum()/len(pixels)).item(),'colors':rows}

