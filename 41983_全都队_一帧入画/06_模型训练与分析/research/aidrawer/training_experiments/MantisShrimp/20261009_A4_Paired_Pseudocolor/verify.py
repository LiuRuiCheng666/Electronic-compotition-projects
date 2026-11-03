"""Meaningful checks of deployment compatibility and rule continuity."""
import importlib.util
from pathlib import Path
import sys
import torch
from models import Student
from target import load_rules, pseudocolor


def main():
    # Load the existing approved topology without importing a painting teacher.
    legacy_path = Path('D:/aidrawer/training_experiments/VanGogh_SelfPortrait/20261008_A4_BN_FromScratch_Vivid_Teacher_ColorPriority/models.py')
    spec = importlib.util.spec_from_file_location('legacy_a4', legacy_path)
    legacy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(legacy)
    old, new = legacy.Student().eval(), Student().eval()
    assert old.state_dict().keys() == new.state_dict().keys()
    new.load_state_dict(old.state_dict(), strict=True)
    torch.manual_seed(7)
    x = torch.rand(1, 3, 48, 64)
    with torch.no_grad():
        assert torch.equal(new(x), old(x)), 'Legacy forward arithmetic differs'
    rules = load_rules()
    # Greys, primaries, colour ramps and threshold crossings.
    ramp = torch.linspace(0, 1, 1024).view(1, 1, 1, -1).expand(1, 3, 16, -1)
    samples = [torch.zeros_like(x), torch.ones_like(x), x, ramp]
    for z in samples:
        y = pseudocolor(z, rules)
        assert torch.equal(y, pseudocolor(z, rules)) and torch.isfinite(y).all()
        assert y.shape == z.shape and y.min() >= 0 and y.max() <= 1
    ramp_y = pseudocolor(ramp, rules)
    assert ramp_y.diff(dim=3).abs().max() < .02, 'Hard colour jump on grey ramp'
    delta = (pseudocolor((x + 1 / 255).clamp(0, 1), rules) - pseudocolor(x, rules)).abs()
    assert delta.mean() < .03 and delta.max() < .15, 'Rule too sensitive to one-level exposure change'
    blue = torch.zeros_like(x); blue[:, 2] = .7
    cyan = pseudocolor(blue, rules).mean((0, 2, 3))
    assert cyan[1] > cyan[0] and cyan[2] > cyan[0], 'Blue should map towards cyan'
    print('PASS: strict legacy state compatibility, identical forward, target determinism/range, grey-ramp continuity, exposure sensitivity and blue-to-cyan')
    print('Exposure delta mean/max:', delta.mean().item(), delta.max().item())


if __name__ == '__main__':
    main()
