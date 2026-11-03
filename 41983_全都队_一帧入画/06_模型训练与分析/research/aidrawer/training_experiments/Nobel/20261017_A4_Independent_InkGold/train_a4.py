"""Paired rule-teacher training. No VGG download, painting teacher or RTL edits."""
import argparse
import hashlib
import json
import math
import random
import time
from pathlib import Path
import torch
import torch.nn.functional as F
from torch import nn
from PIL import Image, ImageDraw
from torchvision.transforms import functional as TF
from torchvision.transforms import RandomResizedCrop
from models import Student
from target import load_rules, nobel_render

CODE = Path(__file__).resolve().parent
OUTPUT = Path('D:/aidrawer/output/Nobel/20261017_A4_Independent_InkGold')
EXTENSIONS = {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def files(directory):
    return sorted(p.resolve() for p in Path(directory).rglob('*') if p.suffix.lower() in EXTENSIONS)


def atomic_save(obj, path):
    tmp = path.with_suffix('.tmp')
    torch.save(obj, tmp)
    tmp.replace(path)


def read_image(path, width, height, augment=False):
    with Image.open(path) as image:
        image = image.convert('RGB')
        if augment:
            top, left, h, w = RandomResizedCrop.get_params(image, scale=(.65, 1.), ratio=(1.1, 1.6))
            image = TF.resized_crop(image, top, left, h, w, (height, width), antialias=True)
            if random.random() < .5:
                image = TF.hflip(image)
        else:
            image = image.resize((width, height), Image.Resampling.BICUBIC)
        x = TF.to_tensor(image)
    if augment:
        # Perturb input BEFORE building its paired target; no target misalignment.
        x = (x * random.uniform(.92, 1.08) + random.uniform(-.015, .015)).clamp(0, 1)
        x = (x + torch.randn_like(x) * random.uniform(0, .003)).clamp(0, 1)
    return x.unsqueeze(0)


def loss_terms(y, target):
    y = y.float()
    ink=(target.amax(1,keepdim=True)<.15).float()
    gold=((target[:,0:1]-target[:,2:3]>.25)&(target[:,1:2]<.7)).float()
    weight=1+4*ink+1.5*gold
    pixel=((y-target).abs()*weight).mean()
    multiscale = sum(F.l1_loss(F.avg_pool2d(y, s), F.avg_pool2d(target, s)) for s in (2, 4, 8)) / 3
    gradient = sum(F.l1_loss(y.diff(dim=d), target.diff(dim=d)) for d in (2, 3)) / 2
    chroma = F.l1_loss(y.amax(1) - y.amin(1), target.amax(1) - target.amin(1))
    # Paired geometry/colour supervision, not input-colour or painting Gram loss.
    return {'pixel': pixel, 'multiscale': multiscale, 'gradient': gradient, 'chroma': chroma}


LOSS_WEIGHTS = {'pixel': 1., 'multiscale': .35, 'gradient': .5, 'chroma': .15}


def architecture(net):
    return {'convolutions': sum(isinstance(m, nn.Conv2d) for m in net.modules()),
            'kernel_weights': sum(m.weight.numel() for m in net.modules() if isinstance(m, nn.Conv2d)),
            'parameters': sum(p.numel() for p in net.parameters()),
            'state_shapes': {k: list(v.shape) for k, v in net.state_dict().items()}}


@torch.no_grad()
def evaluate(net, paths, out, args, rules, device):
    out.mkdir(parents=True, exist_ok=False)
    net.eval()
    metrics = []
    for i, path in enumerate(paths):
        x = read_image(path, args.width, args.height).to(device)
        target = nobel_render(x, rules)
        y = net(x)
        mse = (y - target).square().mean().item()
        # Exposure sensitivity relative to the continuous rule, not a video test.
        x2 = (x + 1 / 255).clamp(0, 1)
        sensitivity = ((net(x2) - y) - (nobel_render(x2, rules) - target)).abs().mean().item()
        metrics.append({'image': str(path), 'mae_u8': (y - target).abs().mean().item() * 255,
                        'psnr_db': -10 * math.log10(max(mse, 1e-12)),
                        'exposure_delta_error_u8': sensitivity * 255})
        panel = Image.new('RGB', (960, 266), 'white')
        draw = ImageDraw.Draw(panel)
        for col, (label, z) in enumerate(zip(['Input', 'Rule target', 'A4 prediction'], [x, target, y])):
            image = TF.to_pil_image(z[0].cpu().clamp(0, 1))
            image.save(out / f'{i:02d}_{["input", "target", "student"][col]}.png')
            panel.paste(image.resize((320, 240)), (col * 320, 26))
            draw.text((col * 320 + 5, 5), label, fill='black')
        panel.save(out / f'panel_{i:02d}.jpg', quality=95)
    (out / 'metrics.json').write_text(json.dumps(metrics, indent=2), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--train-dir', default='D:/aidrawer/data/val2017')
    parser.add_argument('--eval-dir', default='D:/aidrawer/data/student_eval_external')
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--rules', type=Path, default=CODE / 'rules.json')
    parser.add_argument('--steps', type=int, default=3000)
    parser.add_argument('--width', type=int, default=640)
    parser.add_argument('--height', type=int, default=480)
    parser.add_argument('--accum', type=int, default=4)
    parser.add_argument('--lr', type=float, default=2e-4)
    parser.add_argument('--save-every', type=int, default=250)
    parser.add_argument('--bn-warmup', type=int, default=250)
    parser.add_argument('--bn-images', type=int, default=64)
    parser.add_argument('--seed', type=int, default=20261017)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--check-only', action='store_true', help='Forward/backward checks; no optimizer step or run artifacts')
    args = parser.parse_args()
    if min(args.steps, args.accum, args.save_every, args.bn_images) < 1 or min(args.width, args.height) < 16:
        raise ValueError('Positive settings and dimensions >=16 required')
    if args.width % 4 or args.height % 4 or args.lr <= 0 or not 0 <= args.bn_warmup < args.steps:
        raise ValueError('Dimensions must be divisible by 4; warmup must be below steps')
    if not torch.cuda.is_available():
        raise RuntimeError('CUDA unavailable; activate the fns environment')
    device = torch.device('cuda')
    random.seed(args.seed)
    torch.manual_seed(args.seed)
    torch.cuda.manual_seed_all(args.seed)
    torch.backends.cuda.matmul.fp32_precision = 'ieee'
    torch.backends.cudnn.conv.fp32_precision = 'ieee'
    rules = load_rules(args.rules)
    net = Student().to(device)
    budget = architecture(net)
    assert budget['convolutions'] == 9 and budget['kernel_weights'] == 1512 and budget['parameters'] == 1623
    paths, ev = files(args.train_dir), files(args.eval_dir)
    if not paths or not ev:
        raise RuntimeError('Training and external evaluation directories must both contain images')
    if args.check_only:
        x = read_image(paths[0], args.width, args.height).to(device)
        target = nobel_render(x, rules)
        net.eval()
        with torch.autocast('cuda', dtype=torch.bfloat16, enabled=torch.cuda.is_bf16_supported()):
            y = net(x)
        assert y.shape == x.shape and torch.isfinite(target).all() and 0 <= target.min() <= target.max() <= 1
        terms = loss_terms(y, target)
        loss = sum(LOSS_WEIGHTS[k] * v for k, v in terms.items())
        loss.backward()
        assert torch.isfinite(loss) and all(p.grad is not None and torch.isfinite(p.grad).all() for p in net.parameters())
        net.zero_grad(set_to_none=True)
        net.train()
        with torch.autocast('cuda', dtype=torch.bfloat16, enabled=torch.cuda.is_bf16_supported()):
            y = net(x)
            warmup_loss = sum(LOSS_WEIGHTS[k] * v for k, v in loss_terms(y, target).items())
        warmup_loss.backward()
        assert torch.isfinite(warmup_loss) and all(p.grad is not None and torch.isfinite(p.grad).all() for p in net.parameters())
        print(json.dumps({'check': 'PASS: VGA eval/train AMP forward, paired target, losses and backward; NO optimizer step',
                          'train_count': len(paths), 'eval_count': len(ev), 'kernel_weights': budget['kernel_weights'],
                          'parameters': budget['parameters'], 'loss': loss.item(), 'gpu_peak_GiB': torch.cuda.max_memory_allocated() / 2**30}, indent=2))
        return
    run = args.output / 'runs/a4'
    if args.resume and not (run / 'last.pth').exists():
        raise RuntimeError('No checkpoint to resume')
    if run.exists() and not args.resume:
        raise RuntimeError('Run exists: use --resume or a new --output')
    ev_manifest = [{'path': str(p), 'sha256': digest(p)} for p in ev]
    ev_hashes = {v['sha256'] for v in ev_manifest}
    train_manifest = [{'path': str(p), 'sha256': digest(p)} for p in paths]
    train_manifest = [v for v in train_manifest if v['sha256'] not in ev_hashes]
    paths = [Path(v['path']) for v in train_manifest]
    if not paths:
        raise RuntimeError('No training data after excluding external evaluation duplicates')
    settings = {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items() if k not in ['resume', 'check_only', 'steps']}
    config = {'settings': settings, 'rules': rules, 'loss_weights': LOSS_WEIGHTS, 'architecture': budget,
              'source_hashes': {name: digest(CODE / name) for name in ['models.py', 'target.py', 'train_a4.py']},
              'train_files': train_manifest, 'eval_files': ev_manifest}
    if args.resume:
        if json.loads((run / 'config.json').read_text(encoding='utf-8')) != config:
            raise RuntimeError('Resume rejected: settings, rules, source or datasets changed')
    run.mkdir(parents=True, exist_ok=True)
    if not args.resume:
        (run / 'config.json').write_text(json.dumps(config, indent=2), encoding='utf-8')
        (run / 'rules.json').write_text(json.dumps(rules, indent=2), encoding='utf-8')
    opt = torch.optim.Adam(net.parameters(), lr=args.lr)
    step, bn_frozen = 0, False
    if args.resume:
        ck = torch.load(run / 'last.pth', map_location=device, weights_only=False)
        net.load_state_dict(ck['model'], strict=True)
        opt.load_state_dict(ck['optim'])
        step, bn_frozen = ck['step'], ck['bn_frozen']
        random.setstate(ck['python_rng'])
        torch.set_rng_state(ck['torch_rng'].cpu())
        torch.cuda.set_rng_state_all([v.cpu() for v in ck['cuda_rng']])
    if step > args.steps:
        raise RuntimeError('Requested steps below checkpoint step')

    def checkpoint():
        atomic_save({'step': step, 'bn_frozen': bn_frozen, 'model': net.state_dict(), 'optim': opt.state_dict(),
                     'python_rng': random.getstate(), 'torch_rng': torch.get_rng_state(),
                     'cuda_rng': torch.cuda.get_rng_state_all()}, run / 'last.pth')

    amp = torch.cuda.is_bf16_supported()
    started = time.time()
    start_step = step
    try:
        while step < args.steps:
            if not bn_frozen and step >= args.bn_warmup:
                # Preserve running statistics learned during warmup; no recalibration.
                bn_frozen = True
                checkpoint()
                print('Training BN statistics frozen without recalibration; affine parameters continue training', flush=True)
            net.train()
            if bn_frozen:
                for m in net.modules():
                    if isinstance(m, nn.BatchNorm2d):
                        m.eval()
            opt.zero_grad(set_to_none=True)
            values = {k: 0. for k in LOSS_WEIGHTS}
            for _ in range(args.accum):
                x = read_image(random.choice(paths), args.width, args.height, augment=True).to(device)
                target = nobel_render(x, rules)
                with torch.autocast('cuda', dtype=torch.bfloat16, enabled=amp):
                    y = net(x)
                    terms = loss_terms(y, target)
                    loss = sum(LOSS_WEIGHTS[k] * v for k, v in terms.items())
                if not torch.isfinite(loss):
                    raise RuntimeError('Nonfinite loss')
                (loss / args.accum).backward()
                for k, v in terms.items():
                    values[k] += v.detach().item() / args.accum
            norm = nn.utils.clip_grad_norm_(net.parameters(), 5.)
            if not torch.isfinite(norm):
                raise RuntimeError('Nonfinite gradient')
            opt.step()
            step += 1
            if step % 20 == 0:
                record = {'step': step, 'bn_frozen': bn_frozen, **values,
                          'weighted_loss': sum(LOSS_WEIGHTS[k] * v for k, v in values.items())}
                with (run / 'history.jsonl').open('a', encoding='utf-8') as f:
                    f.write(json.dumps(record) + '\n')
                print(f'Step {step}/{args.steps} loss={record["weighted_loss"]:.5f} {(time.time()-started)/(step-start_step):.2f}s/step', flush=True)
            if step % args.save_every == 0 or step == args.steps:
                checkpoint()
                atomic_save(net.state_dict(), run / f'model_step{step:06d}.pth')
                del x, target, y, terms, loss
                evaluate(net, ev, run / f'eval_step{step:06d}_{time.time_ns()}', args, rules, device)
    except KeyboardInterrupt:
        print('Stopped. Resume last complete checkpoint; partial accumulation is discarded.', flush=True)
        return
    # Preserve the BN statistics used by the final training steps. Changing
    # them after optimization changes the network even when weights are fixed.
    # If a very short run never reached BN freeze, retain its learned running
    # statistics too; do not silently recalibrate at export.
    net.eval()
    bn_frozen = True
    checkpoint()
    final_eval = run / f'eval_final_{step:06d}_{time.time_ns()}'
    frozen_bn = {k: v.detach().clone() for k, v in net.state_dict().items()
                 if k.endswith('.running_mean') or k.endswith('.running_var')}
    evaluate(net, ev, final_eval, args, rules, device)
    if any(not torch.equal(v, net.state_dict()[k]) for k, v in frozen_bn.items()):
        raise RuntimeError('Final evaluation changed frozen BN statistics; refusing export')
    atomic_save(net.state_dict(), run / 'model_final.pth')
    (run / 'completed.json').write_text(json.dumps({'step': step, 'evaluation': str(final_eval),
                                                  'sha256': digest(run / 'model_final.pth'), 'bn_export_policy': 'preserve_training_statistics'}), encoding='utf-8')
    print('Completed:', run, flush=True)


if __name__ == '__main__':
    main()
