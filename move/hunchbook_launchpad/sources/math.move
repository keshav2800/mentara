// Q64.64 sqrt-price fixed-point math for the bonding curve, mirroring the
// segment integrals Meteora DBC uses (standard CLMM math):
//
//   price P of one raw base unit, in raw quote units = (sqrt_price / 2^64)^2
//   Δquote = L · (√Pb − √Pa)                    (quote to move price a → b)
//   Δbase  = L · (1/√Pa − 1/√Pb)                (base released doing so)
//
// All intermediates are u256. Rounding is always against the trader: token
// output rounds down, quote output rounds down, price movement rounds so the
// pool keeps the dust. Inputs are bounded by config validation (see
// `config.move`: sqrt prices ≤ 2^84, liquidity ≤ 2^100) which keeps every
// u256 intermediate below 2^249.
module hunchbook_launchpad::math;

const E_SQRT_ORDER: u64 = 100;
const E_ZERO_LIQUIDITY: u64 = 101;
const E_AMOUNT_OVERFLOW: u64 = 102;

const U64_MAX: u256 = 0xFFFFFFFFFFFFFFFF;

/// Quote needed to move the price from `sqrt_a` up to `sqrt_b` under
/// liquidity `l`:  L · (√Pb − √Pa) / 2^64.
public(package) fun delta_quote(l: u128, sqrt_a: u128, sqrt_b: u128, round_up: bool): u64 {
    assert!(sqrt_b >= sqrt_a, E_SQRT_ORDER);
    assert!(l > 0, E_ZERO_LIQUIDITY);
    let num = (l as u256) * ((sqrt_b - sqrt_a) as u256);
    let q64_minus_1 = (1u256 << 64) - 1;
    let out = if (round_up) { (num + q64_minus_1) >> 64 } else { num >> 64 };
    assert!(out <= U64_MAX, E_AMOUNT_OVERFLOW);
    out as u64
}

/// Base released moving the price from `sqrt_a` up to `sqrt_b` (or base
/// absorbed moving down b → a):  L · (√Pb − √Pa) · 2^64 / (√Pa · √Pb).
public(package) fun delta_base(l: u128, sqrt_a: u128, sqrt_b: u128, round_up: bool): u64 {
    assert!(sqrt_b >= sqrt_a, E_SQRT_ORDER);
    assert!(l > 0 && sqrt_a > 0, E_ZERO_LIQUIDITY);
    let num = ((l as u256) * ((sqrt_b - sqrt_a) as u256)) << 64;
    let den = (sqrt_a as u256) * (sqrt_b as u256);
    let out = if (round_up) { (num + den - 1) / den } else { num / den };
    assert!(out <= U64_MAX, E_AMOUNT_OVERFLOW);
    out as u64
}

/// New sqrt price after paying `quote_in` into liquidity `l` at `sqrt_a`:
/// √P' = √Pa + quote_in · 2^64 / L. Rounds down (price moves slightly less
/// for the quote paid — pool keeps the dust).
public(package) fun next_sqrt_from_quote_in(l: u128, sqrt_a: u128, quote_in: u64): u128 {
    assert!(l > 0, E_ZERO_LIQUIDITY);
    let step = ((quote_in as u256) << 64) / (l as u256);
    ((sqrt_a as u256) + step) as u128
}

/// New sqrt price after selling `base_in` into liquidity `l` at `sqrt_a`
/// (price falls): √P' = L·2^64 · √Pa / (L·2^64 + base_in · √Pa).
/// Rounds up (price falls slightly less — the seller receives less quote).
public(package) fun next_sqrt_from_base_in(l: u128, sqrt_a: u128, base_in: u64): u128 {
    assert!(l > 0 && sqrt_a > 0, E_ZERO_LIQUIDITY);
    let l_shifted = (l as u256) << 64;
    let num = l_shifted * (sqrt_a as u256);
    let den = l_shifted + (base_in as u256) * (sqrt_a as u256);
    ((num + den - 1) / den) as u128
}

/// ceil(amount × fee_num / denom) — fee rounding always favours the pool.
public(package) fun fee_amount(amount: u64, fee_num: u64, denom: u64): u64 {
    (((amount as u128) * (fee_num as u128) + ((denom - 1) as u128)) / (denom as u128)) as u64
}

// === test-only wrappers ===

#[test_only]
public fun delta_quote_for_testing(l: u128, a: u128, b: u128, up: bool): u64 {
    delta_quote(l, a, b, up)
}

#[test_only]
public fun delta_base_for_testing(l: u128, a: u128, b: u128, up: bool): u64 {
    delta_base(l, a, b, up)
}

#[test_only]
public fun next_sqrt_from_quote_in_for_testing(l: u128, a: u128, q: u64): u128 {
    next_sqrt_from_quote_in(l, a, q)
}

#[test_only]
public fun next_sqrt_from_base_in_for_testing(l: u128, a: u128, b: u64): u128 {
    next_sqrt_from_base_in(l, a, b)
}
