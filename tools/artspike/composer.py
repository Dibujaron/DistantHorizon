"""composer — M3.5 part-composer pipeline (PR 1).

Ships are ordered Layer lists. Each layer carries an SVG fragment plus an
AUTHORED height profile — a drum says "I'm a cylinder", a wing says "I'm a
flat plate", a fuselage says "I'm a rounded solid". Heights compose in
painter's order exactly like albedo. Normals are derived from the composed
authored heights; nothing is inferred from the whole-ship silhouette (the
round-3 doming rule was spike-only and is rejected for production — it fails
on non-blob hulls like the Thumper).

Roles: "albedo" is real geometry/paint; "sheet_only" is painted pseudo-light
kept for the legacy sheets but dropped from lit-pipeline albedo (which is
authored FLAT); "glow" is engine glow, excluded from exports entirely —
plumes become throttle-driven dynamic art, and the composer emits nozzle
anchors instead.
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Height:
    kind: str            # "flat" | "cyl_x" | "dome"
    lo: float = 0.0
    hi: float = 0.0
    blur: float = 0.0    # model-unit sigma, dome smoothing only


def flat(v):
    return Height("flat", v, v)


def cyl_x(lo, hi):
    """cylinder profile across the part's x-extent, per pixel row — follows
    the part's own silhouette (capsule ends taper naturally)"""
    return Height("cyl_x", lo, hi)


def dome(lo, hi, blur=6.0):
    """rounded-solid profile from the PART's own footprint (a deliberate,
    authored choice for blobby fuselages — not a default)"""
    return Height("dome", lo, hi, blur)


@dataclass(frozen=True)
class Anchor:
    kind: str            # "nozzle"
    x: float             # model units
    y: float


@dataclass
class Layer:
    svg: str
    height: Height | None = None   # None = paint: no relief contribution
    role: str = "albedo"           # albedo | sheet_only | glow


@dataclass
class Hull:
    layers: list = field(default_factory=list)
    anchors: list = field(default_factory=list)


def flatten(hull_or_str, sheet=True):
    """Hull -> single SVG string. sheet=True reproduces the legacy sheet look
    (painted highlights + engine glow); sheet=False is the flat lit-pipeline
    albedo (no painted light, no emissive)."""
    if isinstance(hull_or_str, str):
        return hull_or_str
    keep = ("albedo", "sheet_only", "glow") if sheet else ("albedo",)
    return "".join(l.svg for l in hull_or_str.layers if l.role in keep)
