"""Pure-Python stand-in for the torch surface frame_diagnostic.py uses.

VERIFICATION AID ONLY -- not a torch replacement, and never used when torch is
importable. It exists so frame_diagnostic._self_test() can execute anywhere,
including CI, which installs numpy/scipy/pandas but no torch.

The point is that a self-test nobody can run is a promise, not evidence. Before
this file was committed, frame_diagnostic.py did a bare `import torch` and its
own docstring said "run it before trusting any number this produces" -- with no
mechanism behind it. Now the four polarities and the 50-case invariant sweep run
on every push.

It verifies the ALGORITHM, not torch-specific behaviour. Real torch may differ
in SVD sign conventions and float32-vs-float64 accumulation, so a green run here
does NOT discharge the need to run against real torch before trusting a
production number. It discharges "does the logic hold", which is what the
polarities assert.

QR is modified Gram-Schmidt; SVD is one-sided Jacobi (M <- M J orthogonalizes
columns, accumulating V; then s_i = ||col_i||, U_i = col_i / s_i, so M = U S V^T).
Both are exact enough at 64x32 and 32x32 for the qualitative thresholds the
self-test asserts. `median` reproduces torch's lower-middle convention.
"""
from __future__ import annotations

import math
import random

_rand = random.Random(0)


class Generator:
    def __init__(self): self._seed = 0
    def manual_seed(self, s): self._seed = s; return self


def _is2d(x): return isinstance(x, list) and x and isinstance(x[0], list)


class Tensor:
    def __init__(self, d): self.d = d

    @property
    def ndim(self): return 2 if _is2d(self.d) else (1 if isinstance(self.d, list) else 0)

    def _ew(self, o, f):
        a = self.d
        if isinstance(o, Tensor): o = o.d
        if not isinstance(o, list):                                   # scalar
            if self.ndim == 2: return Tensor([[f(v, o) for v in r] for r in a])
            if self.ndim == 1: return Tensor([f(v, o) for v in a])
            return Tensor(f(a, o))
        if self.ndim == 2 and _is2d(o):
            if len(o) == 1:                                           # (n,d) op (1,d)
                return Tensor([[f(v, o[0][j]) for j, v in enumerate(r)] for r in a])
            return Tensor([[f(v, o[i][j]) for j, v in enumerate(r)] for i, r in enumerate(a)])
        if self.ndim == 2 and not _is2d(o):                           # (n,d) op (d,)
            return Tensor([[f(v, o[j]) for j, v in enumerate(r)] for r in a])
        return Tensor([f(v, o[i]) for i, v in enumerate(a)])

    def __sub__(self, o): return self._ew(o, lambda x, y: x - y)
    def __rsub__(self, o): return Tensor(o)._ew(self, lambda x, y: x - y)
    def __add__(self, o): return self._ew(o, lambda x, y: x + y)
    __radd__ = __add__
    def __mul__(self, o): return self._ew(o, lambda x, y: x * y)
    __rmul__ = __mul__
    def __truediv__(self, o): return self._ew(o, lambda x, y: x / y)
    def __neg__(self): return self * -1
    def __gt__(self, o): return self._ew(o, lambda x, y: x > y)
    def __le__(self, o): return self._ew(o, lambda x, y: x <= y)

    def __matmul__(self, o):
        a, b = self.d, o.d if isinstance(o, Tensor) else o
        bt = list(zip(*b))
        return Tensor([[sum(x * y for x, y in zip(r, c)) for c in bt] for r in a])

    def __getitem__(self, k):
        if isinstance(k, Tensor):
            return Tensor([v for v, m in zip(self.d, k.d) if m])
        return Tensor(self.d[k])

    def __len__(self): return len(self.d)
    def __float__(self): return float(self.d)

    @property
    def shape(self):
        return (len(self.d), len(self.d[0])) if _is2d(self.d) else (len(self.d),)

    @property
    def T(self): return Tensor([list(c) for c in zip(*self.d)])

    def norm(self, dim=None):
        if dim == 1: return Tensor([math.sqrt(sum(v * v for v in r)) for r in self.d])
        return Tensor(math.sqrt(sum(v * v for r in self.d for v in (r if isinstance(r, list) else [r]))))

    def median(self):
        f = sorted(self.d)
        return Tensor(f[(len(f) - 1) // 2]) if f else Tensor(float("nan"))

    def mean(self, dim=None, keepdim=False):
        n = len(self.d)
        cols = [sum(c) / n for c in zip(*self.d)]
        return Tensor([cols] if keepdim else cols)

    def any(self): return any(self.d)
    def clamp(self, lo, hi): return self._ew(None, lambda x, _: max(lo, min(hi, x))) if False else \
        Tensor([max(lo, min(hi, v)) for v in self.d])
    def tolist(self): return self.d


def manual_seed(s):
    global _rand
    _rand = random.Random(s)


def randn(*shape, generator=None):
    r = random.Random(generator._seed) if generator is not None else _rand
    if len(shape) == 1: return Tensor([r.gauss(0, 1) for _ in range(shape[0])])
    return Tensor([[r.gauss(0, 1) for _ in range(shape[1])] for _ in range(shape[0])])


def eye(d): return Tensor([[1.0 if i==j else 0.0 for j in range(d)] for i in range(d)])


def zeros(*shape): return Tensor([0.0] * (shape[0] if shape else 0))
def linspace(a, b, n): return Tensor([a + (b - a) * i / (n - 1) for i in range(n)])


def _mgs(a):
    """Modified Gram-Schmidt QR on columns. a is (m,n) row-major."""
    cols = [list(c) for c in zip(*a)]
    q = []
    for v in cols:
        for u in q:
            p = sum(x * y for x, y in zip(u, v))
            v = [x - p * y for x, y in zip(v, u)]
        nrm = math.sqrt(sum(x * x for x in v))
        q.append([x / nrm for x in v] if nrm > 1e-12 else [0.0] * len(v))
    return [list(r) for r in zip(*q)]


def _jacobi_svd(a, sweeps=60):
    """One-sided Jacobi. Returns (U, s, Vh) with a = U diag(s) Vh."""
    m = [list(r) for r in a]
    n = len(m[0])
    v = [[1.0 if i == j else 0.0 for j in range(n)] for i in range(n)]
    for _ in range(sweeps):
        off = 0.0
        for p in range(n - 1):
            for q in range(p + 1, n):
                alpha = sum(r[p] * r[p] for r in m)
                beta = sum(r[q] * r[q] for r in m)
                gamma = sum(r[p] * r[q] for r in m)
                if abs(gamma) < 1e-15: continue
                off += gamma * gamma
                zeta = (beta - alpha) / (2.0 * gamma)
                t = math.copysign(1.0, zeta) / (abs(zeta) + math.sqrt(1.0 + zeta * zeta))
                c = 1.0 / math.sqrt(1.0 + t * t)
                s = c * t
                for r in m:
                    rp, rq = r[p], r[q]
                    r[p], r[q] = c * rp - s * rq, s * rp + c * rq
                for r in v:
                    rp, rq = r[p], r[q]
                    r[p], r[q] = c * rp - s * rq, s * rp + c * rq
        if off < 1e-30: break
    sv = [math.sqrt(sum(r[j] * r[j] for r in m)) for j in range(n)]
    order = sorted(range(n), key=lambda j: -sv[j])
    u = [[(m[i][j] / sv[j] if sv[j] > 1e-12 else 0.0) for j in order] for i in range(len(m))]
    vh = [[v[i][j] for i in range(n)] for j in order]
    return u, [sv[j] for j in order], vh


class _Linalg:
    @staticmethod
    def norm(x): return x.norm()

    @staticmethod
    def qr(x): return Tensor(_mgs(x.d)), None

    @staticmethod
    def svd(x, full_matrices=False):
        u, s, vh = _jacobi_svd(x.d)
        return Tensor(u), Tensor(s), Tensor(vh)

    @staticmethod
    def svdvals(x): return Tensor(_jacobi_svd(x.d)[1])


linalg = _Linalg()


def no_grad():
    class _Ctx:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def __call__(self, fn): return fn
    return _Ctx()
