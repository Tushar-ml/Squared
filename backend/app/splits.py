"""Split calculation. All amounts are integer minor units; shares always sum exactly to the total."""
from decimal import ROUND_FLOOR, Decimal, InvalidOperation

SPLIT_TYPES = ("EQUAL", "EXACT", "PERCENT", "SHARES")


class SplitError(ValueError):
    pass


def allocate(total: int, weights: list) -> list[int]:
    """Largest-remainder apportionment of `total` by non-negative `weights`.

    Deterministic: ties go to the earlier position, so equal splits give the extra
    paisa to the first people in the list.
    """
    w = [Decimal(str(x)) for x in weights]
    if any(x < 0 for x in w):
        raise SplitError("Split values can't be negative")
    s = sum(w)
    if s <= 0:
        raise SplitError("Split values must add up to more than zero")
    raw = [Decimal(total) * x / s for x in w]
    base = [int(r.to_integral_value(rounding=ROUND_FLOOR)) for r in raw]
    left = total - sum(base)
    order = sorted(range(len(w)), key=lambda i: (-(raw[i] - base[i]), i))
    for i in order[:left]:
        base[i] += 1
    return base


def _num(v, what) -> Decimal:
    try:
        d = Decimal(str(v))
    except (InvalidOperation, ValueError):
        raise SplitError(f"{what} must be a number")
    if not d.is_finite():
        raise SplitError(f"{what} must be a number")
    return d


def compute(amount: int, split_type: str, members: set[int], *, participants=None, exact=None,
            percents=None, shares=None) -> tuple[dict[int, int], dict]:
    """Return ({user_id: minor units}, meta) where meta stores the user's inputs for later edits."""
    if amount <= 0:
        raise SplitError("Amount must be more than zero")
    split_type = (split_type or "EQUAL").upper()
    if split_type not in SPLIT_TYPES:
        raise SplitError("Unknown split type")

    def check_members(ids):
        if not ids:
            raise SplitError("Pick at least one person")
        if not set(ids) <= members:
            raise SplitError("Everyone in the split must be in the group")

    if split_type == "EQUAL":
        ids = sorted(set(participants or members))
        check_members(ids)
        out = dict(zip(ids, allocate(amount, [1] * len(ids))))
        return out, {"participants": ids}

    if split_type == "EXACT":
        vals = {int(k): int(_num(v, "Amount")) for k, v in (exact or {}).items()}
        vals = {k: v for k, v in vals.items() if v != 0}
        check_members(list(vals))
        if any(v < 0 for v in vals.values()):
            raise SplitError("Amounts can't be negative")
        total = sum(vals.values())
        if total != amount:
            diff = amount - total
            raise SplitError(f"Amounts are {'short' if diff > 0 else 'over'} by {abs(diff) / 100:.2f}")
        return vals, {"exact": {str(k): v for k, v in vals.items()}}

    if split_type == "PERCENT":
        vals = {int(k): _num(v, "Percent") for k, v in (percents or {}).items()}
        vals = {k: v for k, v in vals.items() if v != 0}
        check_members(list(vals))
        if any(v < 0 for v in vals.values()):
            raise SplitError("Percentages can't be negative")
        total = sum(vals.values())
        if abs(total - 100) > Decimal("0.01"):
            raise SplitError(f"Percentages add up to {total.normalize():f}%, not 100%")
        ids = sorted(vals)
        out = dict(zip(ids, allocate(amount, [vals[i] for i in ids])))
        return out, {"percents": {str(k): float(vals[k]) for k in ids}}

    # SHARES
    vals = {int(k): _num(v, "Shares") for k, v in (shares or {}).items()}
    vals = {k: v for k, v in vals.items() if v != 0}
    check_members(list(vals))
    if any(v < 0 for v in vals.values()):
        raise SplitError("Shares can't be negative")
    ids = sorted(vals)
    out = dict(zip(ids, allocate(amount, [vals[i] for i in ids])))
    return out, {"shares": {str(k): float(vals[k]) for k in ids}}


def reallocate(new_total: int, shares: dict[int, int]) -> dict[int, int]:
    """Scale shares computed in one currency onto a total in another, keeping exact sums."""
    ids = sorted(shares)
    return dict(zip(ids, allocate(new_total, [shares[i] for i in ids])))
