// PoolConfig — the reusable "launch template" (Meteora DBC's config account).
// A partner (launchpad operator) creates one config; every pool launched
// against it inherits the same curve shape, fee scheduler, splits and
// migration rules. Configs are shared and immutable after creation: to change
// economics, create a new config.
//
// Derived-at-creation invariants (validated here, relied on by `pool.move`):
//   - the curve can absorb at least `migration_quote_threshold` quote
//   - `migration_sqrt_price` is exactly where the quote integral hits the
//     threshold, so the graduated DEX pool opens gap-free
//   - `initial_base_supply = swap_base·1.25 (sell-back buffer) + migration base`
module hunchbook_launchpad::config;

use hunchbook_launchpad::math;
use std::type_name::{Self, TypeName};
use sui::event;

// === fee system constants (DBC-compatible) ===

/// All fee rates are numerators over this denominator. 1% = 10_000_000.
const FEE_DENOM: u64 = 1_000_000_000;
/// 25 bps — hard floor for any trading fee.
const MIN_FEE_NUM: u64 = 2_500_000;
/// 99% — hard ceiling (scheduler cliffs live below this).
const MAX_FEE_NUM: u64 = 990_000_000;
/// Protocol ("brain" company) share of every trading fee, in percent.
const PROTOCOL_FEE_PCT: u64 = 20;
/// Protocol's cut of migrated liquidity at graduation, in bps (DBC's 0.2%).
const PROTOCOL_MIGRATION_LIQ_FEE_BPS: u64 = 20;
/// The "brain" company wallet — receives the 20% protocol cut of every fee
/// and the 20 bps migration liquidity fee. Hardcoded like the router's
/// FEE_RECIPIENT; immutable for the life of the package. Currently the
/// shared treasury — REPLACE with the dedicated protocol wallet before the
/// mainnet publish.
const PROTOCOL_FEE_RECIPIENT: address =
    @0x7ceebdaeab0ba4a02ed5cd7775a6e73f29748c55fd94bfd650aee277543ab1a7;
/// Extra base tokens minted on top of the curve sale, in percent, so
/// sell-backs during bonding can always be re-bought (DBC's 25% buffer).
const BUFFER_PCT: u64 = 25;

// === curve bounds ===
// These keep every u256 intermediate in math.move below 2^249 (see there).

const MAX_CURVE_POINTS: u64 = 16;
const MIN_SQRT_PRICE: u128 = 4295048016;
const MAX_SQRT_PRICE: u128 = 1 << 84;
const MAX_LIQUIDITY: u128 = 1 << 100;

// === fee scheduler modes ===

const FEE_MODE_FLAT: u8 = 0;
const FEE_MODE_LINEAR: u8 = 1;
const FEE_MODE_EXPONENTIAL: u8 = 2;
/// Exponential reduction is expressed in bps-of-current-fee per period.
const SCHEDULER_BPS_DENOM: u128 = 10_000;
/// Cap on scheduler periods (bounds the exp-decay loop).
const MAX_PERIODS: u64 = 1_440;

// === errors ===

const E_BAD_CURVE: u64 = 0;
const E_BAD_FEE: u64 = 1;
const E_BAD_SCHEDULER: u64 = 2;
const E_BAD_SPLIT: u64 = 3;
const E_THRESHOLD_UNREACHABLE: u64 = 4;
const E_BAD_THRESHOLD: u64 = 5;
const E_BAD_DECIMALS: u64 = 6;
const E_SELL_BELOW_START: u64 = 7;
const E_CURVE_EXHAUSTED: u64 = 8;

public struct CurvePoint has copy, drop, store {
    /// Upper sqrt-price bound of this segment (Q64.64).
    sqrt_price: u128,
    /// Virtual liquidity active while the price is inside this segment.
    liquidity: u128,
}

public struct PoolConfig has key {
    id: UID,
    /// Quote coin type every pool on this config trades against (e.g. USDC).
    quote_type: TypeName,
    /// Wallet the partner's (Hunchbook's) fee share is claimed to.
    partner_fee_claimer: address,
    /// Wallet leftover base tokens are withdrawn to post-migration.
    leftover_receiver: address,
    // --- curve shape ---
    sqrt_start_price: u128,
    curve: vector<CurvePoint>,
    // --- fee scheduler (anti-sniper decay) ---
    fee_mode: u8,
    cliff_fee_num: u64,
    period_freq_ms: u64,
    fee_reduction: u64,
    n_periods: u64,
    /// Pool's very first swap pays MIN_FEE_NUM (creator first-buy support).
    first_swap_min_fee: bool,
    // --- splits (percent) ---
    /// Creator's share of the LP fee (the 80% left after protocol's 20%).
    /// Owner decision: 50 → per trade 20% protocol / 40% partner / 40% creator.
    creator_lp_fee_pct: u64,
    /// Percent of the migration quote taken as a fee at graduation.
    migration_fee_pct: u64,
    /// Creator's share of that migration fee.
    creator_migration_fee_pct: u64,
    /// Trading fee of the graduated AMM pool (over FEE_DENOM).
    amm_fee_num: u64,
    // --- lifecycle ---
    migration_quote_threshold: u64,
    pool_creation_fee: u64,
    activation_delay_ms: u64,
    token_decimals: u8,
    // --- derived at create_config ---
    migration_sqrt_price: u128,
    swap_base_amount: u64,
    migration_base_amount: u64,
    initial_base_supply: u64,
}

public struct ConfigCreated has copy, drop {
    config_id: ID,
    quote_type: std::ascii::String,
    migration_quote_threshold: u64,
    sqrt_start_price: u128,
    migration_sqrt_price: u128,
    initial_base_supply: u64,
}

public fun curve_point(sqrt_price: u128, liquidity: u128): CurvePoint {
    CurvePoint { sqrt_price, liquidity }
}

/// Curve is passed as parallel primitive vectors (zipped here) because
/// struct vectors cannot be encoded as PTB pure arguments.
#[allow(lint(share_owned))]
public fun create_config<Q>(
    partner_fee_claimer: address,
    leftover_receiver: address,
    sqrt_start_price: u128,
    curve_sqrt_prices: vector<u128>,
    curve_liquidities: vector<u128>,
    fee_mode: u8,
    cliff_fee_num: u64,
    period_freq_ms: u64,
    fee_reduction: u64,
    n_periods: u64,
    first_swap_min_fee: bool,
    creator_lp_fee_pct: u64,
    migration_fee_pct: u64,
    creator_migration_fee_pct: u64,
    amm_fee_num: u64,
    migration_quote_threshold: u64,
    pool_creation_fee: u64,
    activation_delay_ms: u64,
    token_decimals: u8,
    ctx: &mut TxContext,
): ID {
    assert!(amm_fee_num >= MIN_FEE_NUM && amm_fee_num <= MAX_FEE_NUM, E_BAD_FEE);
    assert!(curve_sqrt_prices.length() == curve_liquidities.length(), E_BAD_CURVE);
    let mut curve = vector<CurvePoint>[];
    let mut i = 0;
    while (i < curve_sqrt_prices.length()) {
        curve.push_back(CurvePoint {
            sqrt_price: curve_sqrt_prices[i],
            liquidity: curve_liquidities[i],
        });
        i = i + 1;
    };
    validate_curve(sqrt_start_price, &curve);
    validate_scheduler(fee_mode, cliff_fee_num, period_freq_ms, fee_reduction, n_periods);
    assert!(creator_lp_fee_pct <= 100, E_BAD_SPLIT);
    assert!(migration_fee_pct <= 50, E_BAD_SPLIT);
    assert!(creator_migration_fee_pct <= 100, E_BAD_SPLIT);
    assert!(migration_quote_threshold > 0, E_BAD_THRESHOLD);
    assert!(token_decimals >= 6 && token_decimals <= 9, E_BAD_DECIMALS);

    let (migration_sqrt_price, swap_base_amount) =
        derive_migration(sqrt_start_price, &curve, migration_quote_threshold);

    // Base side of the graduated DEX pool: the post-migration-fee quote,
    // valued at the migration price.  base = quote · 2^128 / (√Pm)².
    let quote_for_lp =
        migration_quote_threshold - migration_quote_threshold * migration_fee_pct / 100;
    let sm = migration_sqrt_price as u256;
    let migration_base_amount = (((quote_for_lp as u256) << 128) / (sm * sm)) as u64;

    let initial_base_supply =
        swap_base_amount + swap_base_amount * BUFFER_PCT / 100 + migration_base_amount;

    let config = PoolConfig {
        id: object::new(ctx),
        quote_type: type_name::with_defining_ids<Q>(),
        partner_fee_claimer,
        leftover_receiver,
        sqrt_start_price,
        curve,
        fee_mode,
        cliff_fee_num,
        period_freq_ms,
        fee_reduction,
        n_periods,
        first_swap_min_fee,
        creator_lp_fee_pct,
        migration_fee_pct,
        creator_migration_fee_pct,
        amm_fee_num,
        migration_quote_threshold,
        pool_creation_fee,
        activation_delay_ms,
        token_decimals,
        migration_sqrt_price,
        swap_base_amount,
        migration_base_amount,
        initial_base_supply,
    };
    let config_id = object::id(&config);
    event::emit(ConfigCreated {
        config_id,
        quote_type: type_name::with_defining_ids<Q>().into_string(),
        migration_quote_threshold,
        sqrt_start_price,
        migration_sqrt_price,
        initial_base_supply,
    });
    transfer::share_object(config);
    config_id
}

// === validation ===

fun validate_curve(sqrt_start_price: u128, curve: &vector<CurvePoint>) {
    let n = curve.length();
    assert!(n >= 1 && n <= MAX_CURVE_POINTS, E_BAD_CURVE);
    assert!(sqrt_start_price >= MIN_SQRT_PRICE, E_BAD_CURVE);
    let mut prev = sqrt_start_price;
    let mut i = 0;
    while (i < n) {
        let pt = &curve[i];
        assert!(pt.sqrt_price > prev && pt.sqrt_price <= MAX_SQRT_PRICE, E_BAD_CURVE);
        assert!(pt.liquidity > 0 && pt.liquidity <= MAX_LIQUIDITY, E_BAD_CURVE);
        prev = pt.sqrt_price;
        i = i + 1;
    };
}

fun validate_scheduler(
    fee_mode: u8,
    cliff_fee_num: u64,
    period_freq_ms: u64,
    fee_reduction: u64,
    n_periods: u64,
) {
    assert!(cliff_fee_num >= MIN_FEE_NUM && cliff_fee_num <= MAX_FEE_NUM, E_BAD_FEE);
    if (fee_mode == FEE_MODE_FLAT) {
        assert!(period_freq_ms == 0 && fee_reduction == 0 && n_periods == 0, E_BAD_SCHEDULER);
    } else if (fee_mode == FEE_MODE_LINEAR) {
        assert!(period_freq_ms > 0 && n_periods > 0 && n_periods <= MAX_PERIODS, E_BAD_SCHEDULER);
        // Terminal fee must stay above the floor.
        assert!(fee_reduction * n_periods < cliff_fee_num, E_BAD_SCHEDULER);
        assert!(cliff_fee_num - fee_reduction * n_periods >= MIN_FEE_NUM, E_BAD_SCHEDULER);
    } else if (fee_mode == FEE_MODE_EXPONENTIAL) {
        assert!(period_freq_ms > 0 && n_periods > 0 && n_periods <= MAX_PERIODS, E_BAD_SCHEDULER);
        assert!(fee_reduction > 0 && (fee_reduction as u128) < SCHEDULER_BPS_DENOM, E_BAD_SCHEDULER);
        assert!(exp_decay(cliff_fee_num, fee_reduction, n_periods) >= MIN_FEE_NUM, E_BAD_SCHEDULER);
    } else {
        abort E_BAD_SCHEDULER
    };
}

// === fee scheduler ===

/// Trading fee numerator in force at `now_ms` for a pool activated at
/// `activation_ms`. `is_first_swap` implements the first-buy-min-fee option.
public(package) fun current_fee_num(
    cfg: &PoolConfig,
    activation_ms: u64,
    now_ms: u64,
    is_first_swap: bool,
): u64 {
    if (is_first_swap && cfg.first_swap_min_fee) return MIN_FEE_NUM;
    if (cfg.fee_mode == FEE_MODE_FLAT) return cfg.cliff_fee_num;
    let elapsed = if (now_ms > activation_ms) now_ms - activation_ms else 0;
    let mut n = elapsed / cfg.period_freq_ms;
    if (n > cfg.n_periods) n = cfg.n_periods;
    if (cfg.fee_mode == FEE_MODE_LINEAR) {
        cfg.cliff_fee_num - cfg.fee_reduction * n
    } else {
        exp_decay(cfg.cliff_fee_num, cfg.fee_reduction, n)
    }
}

/// fee · (1 − reduction/10000)^n, loop bounded by MAX_PERIODS.
fun exp_decay(cliff_fee_num: u64, fee_reduction: u64, n: u64): u64 {
    let keep = SCHEDULER_BPS_DENOM - (fee_reduction as u128);
    let mut fee = cliff_fee_num as u128;
    let mut i = 0;
    while (i < n) {
        fee = fee * keep / SCHEDULER_BPS_DENOM;
        i = i + 1;
    };
    fee as u64
}

// === curve walking ===

/// Walk the curve upward buying with `quote_in` (net of fees, already capped
/// at remaining threshold capacity by the caller). Returns
/// (base_out, new_sqrt_price). Aborts if the curve can't absorb the amount —
/// unreachable when the caller caps at the threshold (validated derivable).
public(package) fun quote_to_base(
    cfg: &PoolConfig,
    sqrt_price: u128,
    quote_in: u64,
): (u64, u128) {
    let mut s = sqrt_price;
    let mut remaining = quote_in;
    let mut base_out: u64 = 0;
    let n = cfg.curve.length();
    let mut i = 0;
    while (i < n && remaining > 0) {
        let pt = &cfg.curve[i];
        if (pt.sqrt_price > s) {
            let dq_band = math::delta_quote(pt.liquidity, s, pt.sqrt_price, true);
            if (remaining < dq_band) {
                let s_new = math::next_sqrt_from_quote_in(pt.liquidity, s, remaining);
                base_out = base_out + math::delta_base(pt.liquidity, s, s_new, false);
                s = s_new;
                remaining = 0;
            } else {
                base_out = base_out + math::delta_base(pt.liquidity, s, pt.sqrt_price, false);
                remaining = remaining - dq_band;
                s = pt.sqrt_price;
            };
        };
        i = i + 1;
    };
    assert!(remaining == 0, E_CURVE_EXHAUSTED);
    (base_out, s)
}

/// Walk the curve downward selling `base_in` tokens. Returns
/// (quote_out, new_sqrt_price). Aborts if the sell would push the price
/// below the start price — impossible for tokens actually bought on the
/// curve (buy outputs round down), so hitting this means a math bug.
public(package) fun base_to_quote(
    cfg: &PoolConfig,
    sqrt_price: u128,
    base_in: u64,
): (u64, u128) {
    let mut s = sqrt_price;
    let mut remaining = base_in;
    let mut quote_out: u64 = 0;
    let n = cfg.curve.length();
    // Segment i spans [lower_i, curve[i].sqrt_price] where lower_0 is the
    // start price and lower_i = curve[i-1].sqrt_price.
    let mut i = n;
    while (i > 0 && remaining > 0) {
        i = i - 1;
        let pt = &cfg.curve[i];
        let lower = if (i == 0) cfg.sqrt_start_price else cfg.curve[i - 1].sqrt_price;
        if (lower < s) {
            let seg_top = if (pt.sqrt_price < s) pt.sqrt_price else s;
            if (seg_top <= lower) continue;
            let db_band = math::delta_base(pt.liquidity, lower, seg_top, true);
            if (remaining < db_band) {
                let s_new = math::next_sqrt_from_base_in(pt.liquidity, seg_top, remaining);
                quote_out = quote_out + math::delta_quote(pt.liquidity, s_new, seg_top, false);
                s = s_new;
                remaining = 0;
            } else {
                quote_out = quote_out + math::delta_quote(pt.liquidity, lower, seg_top, false);
                remaining = remaining - db_band;
                s = lower;
            };
        };
    };
    assert!(remaining == 0, E_SELL_BELOW_START);
    (quote_out, s)
}

/// Find where the quote integral from the start price hits `threshold`,
/// and the base sold getting there. Aborts if the curve is too small.
fun derive_migration(
    sqrt_start_price: u128,
    curve: &vector<CurvePoint>,
    threshold: u64,
): (u128, u64) {
    let mut s = sqrt_start_price;
    let mut acc: u64 = 0;
    let mut base_sold: u64 = 0;
    let n = curve.length();
    let mut i = 0;
    while (i < n) {
        let pt = &curve[i];
        let dq_band = math::delta_quote(pt.liquidity, s, pt.sqrt_price, true);
        if (acc + dq_band >= threshold) {
            let remaining = threshold - acc;
            let mut sm = math::next_sqrt_from_quote_in(pt.liquidity, s, remaining);
            if (sm > pt.sqrt_price) sm = pt.sqrt_price;
            base_sold = base_sold + math::delta_base(pt.liquidity, s, sm, false);
            return (sm, base_sold)
        };
        acc = acc + dq_band;
        base_sold = base_sold + math::delta_base(pt.liquidity, s, pt.sqrt_price, false);
        s = pt.sqrt_price;
        i = i + 1;
    };
    abort E_THRESHOLD_UNREACHABLE
}

// === splits ===

/// Split a fee into (protocol, partner, creator) per the waterfall:
/// protocol 20%, remainder split by `creator_pct`. Used by both the bonding
/// curve and the graduated AMM — one rule everywhere.
public(package) fun split_fee(fee: u64, creator_pct: u64): (u64, u64, u64) {
    let protocol = fee * PROTOCOL_FEE_PCT / 100;
    let lp = fee - protocol;
    let creator = lp * creator_pct / 100;
    (protocol, lp - creator, creator)
}

public(package) fun split_trading_fee(cfg: &PoolConfig, fee: u64): (u64, u64, u64) {
    split_fee(fee, cfg.creator_lp_fee_pct)
}

// === getters ===

public fun quote_type(cfg: &PoolConfig): TypeName { cfg.quote_type }

public fun partner_fee_claimer(cfg: &PoolConfig): address { cfg.partner_fee_claimer }

public fun leftover_receiver(cfg: &PoolConfig): address { cfg.leftover_receiver }

public fun sqrt_start_price(cfg: &PoolConfig): u128 { cfg.sqrt_start_price }

public fun migration_quote_threshold(cfg: &PoolConfig): u64 { cfg.migration_quote_threshold }

public fun migration_sqrt_price(cfg: &PoolConfig): u128 { cfg.migration_sqrt_price }

public fun swap_base_amount(cfg: &PoolConfig): u64 { cfg.swap_base_amount }

public fun migration_base_amount(cfg: &PoolConfig): u64 { cfg.migration_base_amount }

public fun initial_base_supply(cfg: &PoolConfig): u64 { cfg.initial_base_supply }

public fun pool_creation_fee(cfg: &PoolConfig): u64 { cfg.pool_creation_fee }

public fun activation_delay_ms(cfg: &PoolConfig): u64 { cfg.activation_delay_ms }

public fun migration_fee_pct(cfg: &PoolConfig): u64 { cfg.migration_fee_pct }

public fun creator_migration_fee_pct(cfg: &PoolConfig): u64 { cfg.creator_migration_fee_pct }

public fun fee_denom(): u64 { FEE_DENOM }

public fun min_fee_num(): u64 { MIN_FEE_NUM }

public fun protocol_fee_recipient(): address { PROTOCOL_FEE_RECIPIENT }

public fun protocol_migration_liq_fee_bps(): u64 { PROTOCOL_MIGRATION_LIQ_FEE_BPS }

public fun creator_lp_fee_pct(cfg: &PoolConfig): u64 { cfg.creator_lp_fee_pct }

public fun amm_fee_num(cfg: &PoolConfig): u64 { cfg.amm_fee_num }

// === test-only ===

#[test_only]
public fun current_fee_num_for_testing(
    cfg: &PoolConfig,
    activation_ms: u64,
    now_ms: u64,
    is_first_swap: bool,
): u64 {
    current_fee_num(cfg, activation_ms, now_ms, is_first_swap)
}

#[test_only]
public fun quote_to_base_for_testing(cfg: &PoolConfig, s: u128, q: u64): (u64, u128) {
    quote_to_base(cfg, s, q)
}

#[test_only]
public fun base_to_quote_for_testing(cfg: &PoolConfig, s: u128, b: u64): (u64, u128) {
    base_to_quote(cfg, s, b)
}

#[test_only]
public fun split_trading_fee_for_testing(cfg: &PoolConfig, fee: u64): (u64, u64, u64) {
    split_trading_fee(cfg, fee)
}
