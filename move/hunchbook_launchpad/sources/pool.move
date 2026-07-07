// VirtualPool — one bonding-curve market per launched coin (Meteora DBC's
// virtual pool). Holds the full minted supply plus every quote coin buyers
// pay in; prices trades by walking the config's curve segments.
//
// Trust properties:
//   - The TreasuryCap is locked inside the pool and this module exposes no
//     mint path → supply is provably fixed at `initial_base_supply`.
//   - Fee balances are separate from `quote_reserve`, so the reserve is
//     always exactly what the curve owes and the graduation trigger is a
//     plain `>= threshold` check.
//   - All fee claims are permissionless but pay to fixed destinations
//     (protocol const / config.partner_fee_claimer / pool.creator), so there
//     is no authority to steal.
//   - The final buy partial-fills to land the reserve exactly on the
//     threshold (refunding the rest), so the graduated DEX pool opens at
//     exactly the derived migration price and no surplus bucket is needed.
module hunchbook_launchpad::pool;

use hunchbook_launchpad::amm;
use hunchbook_launchpad::config::{Self, PoolConfig};
use hunchbook_launchpad::math;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::table::{Self, Table};

/// Pool creation fee split: 10% protocol / 90% partner (DBC convention).
const CREATION_FEE_PROTOCOL_PCT: u64 = 10;

const E_PAUSED: u64 = 200;
const E_WRONG_QUOTE: u64 = 201;
const E_SUPPLY_NOT_ZERO: u64 = 202;
const E_WRONG_CREATION_FEE: u64 = 203;
const E_WRONG_CONFIG: u64 = 204;
const E_COMPLETED: u64 = 205;
const E_NOT_ACTIVE: u64 = 206;
const E_ZERO_AMOUNT: u64 = 207;
const E_SLIPPAGE: u64 = 208;
const E_INSOLVENT: u64 = 209;
const E_NOT_COMPLETED: u64 = 210;
const E_ALREADY_MIGRATED: u64 = 211;

public struct Registry has key {
    id: UID,
    /// coin type → pool id; enforces one pool per coin type, forever.
    pools: Table<TypeName, ID>,
    pool_count: u64,
    /// Pauses new pool creation only — never trading or user funds.
    paused: bool,
}

public struct AdminCap has key, store { id: UID }

public struct VirtualPool<phantom B, phantom Q> has key {
    id: UID,
    config_id: ID,
    creator: address,
    /// Locked forever; no mint path exists in this module.
    treasury_cap: TreasuryCap<B>,
    base_reserve: Balance<B>,
    quote_reserve: Balance<Q>,
    sqrt_price: u128,
    activation_ms: u64,
    swap_count: u64,
    is_completed: bool,
    is_migrated: bool,
    finish_ms: u64,
    fee_protocol: Balance<Q>,
    fee_partner: Balance<Q>,
    fee_creator: Balance<Q>,
}

// === events ===

public struct PoolCreated has copy, drop {
    pool_id: ID,
    config_id: ID,
    coin_type: std::ascii::String,
    creator: address,
    initial_base_supply: u64,
    sqrt_start_price: u128,
    activation_ms: u64,
    timestamp_ms: u64,
}

public struct Swap has copy, drop {
    pool_id: ID,
    trader: address,
    is_buy: bool,
    /// Gross coin the trader put in (quote for buys, base for sells).
    amount_in: u64,
    /// Net coin the trader received (base for buys, quote for sells).
    amount_out: u64,
    fee: u64,
    protocol_fee: u64,
    partner_fee: u64,
    creator_fee: u64,
    sqrt_price_after: u128,
    quote_reserve_after: u64,
    timestamp_ms: u64,
}

public struct CurveComplete has copy, drop {
    pool_id: ID,
    quote_reserve: u64,
    finish_ms: u64,
}

public struct FeesClaimed has copy, drop {
    pool_id: ID,
    /// 0 = protocol, 1 = partner, 2 = creator
    kind: u8,
    amount: u64,
    recipient: address,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        pools: table::new(ctx),
        pool_count: 0,
        paused: false,
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

public fun set_paused(_: &AdminCap, registry: &mut Registry, paused: bool) {
    registry.paused = paused;
}

// === pool creation ===

/// Open the bonding-curve market for coin `B`. Called by the publisher
/// (our treasury) right after publishing the coin package; `creator` is the
/// end user being attributed. The cap must be unused: the full supply is
/// minted here, once, and the cap is locked inside the pool.
public fun create_pool<B, Q>(
    registry: &mut Registry,
    cfg: &PoolConfig,
    mut treasury_cap: TreasuryCap<B>,
    creator: address,
    creation_fee: Coin<Q>,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(!registry.paused, E_PAUSED);
    assert!(type_name::with_defining_ids<Q>() == cfg.quote_type(), E_WRONG_QUOTE);
    assert!(coin::total_supply(&treasury_cap) == 0, E_SUPPLY_NOT_ZERO);
    assert!(creation_fee.value() == cfg.pool_creation_fee(), E_WRONG_CREATION_FEE);

    pay_creation_fee(cfg, creation_fee, ctx);

    let supply = cfg.initial_base_supply();
    let base_reserve = coin::mint_balance(&mut treasury_cap, supply);
    let now = clock.timestamp_ms();
    let activation_ms = now + cfg.activation_delay_ms();

    let pool = VirtualPool<B, Q> {
        id: object::new(ctx),
        config_id: object::id(cfg),
        creator,
        treasury_cap,
        base_reserve,
        quote_reserve: balance::zero(),
        sqrt_price: cfg.sqrt_start_price(),
        activation_ms,
        swap_count: 0,
        is_completed: false,
        is_migrated: false,
        finish_ms: 0,
        fee_protocol: balance::zero(),
        fee_partner: balance::zero(),
        fee_creator: balance::zero(),
    };
    let pool_id = object::id(&pool);
    // Aborts on duplicate coin type — one pool per coin, ever.
    registry.pools.add(type_name::with_defining_ids<B>(), pool_id);
    registry.pool_count = registry.pool_count + 1;

    event::emit(PoolCreated {
        pool_id,
        config_id: object::id(cfg),
        coin_type: type_name::with_defining_ids<B>().into_string(),
        creator,
        initial_base_supply: supply,
        sqrt_start_price: cfg.sqrt_start_price(),
        activation_ms,
        timestamp_ms: now,
    });
    transfer::share_object(pool);
    pool_id
}

fun pay_creation_fee<Q>(cfg: &PoolConfig, mut fee: Coin<Q>, ctx: &mut TxContext) {
    if (fee.value() == 0) {
        fee.destroy_zero();
        return
    };
    let protocol_cut = fee.value() * CREATION_FEE_PROTOCOL_PCT / 100;
    if (protocol_cut > 0) {
        transfer::public_transfer(
            fee.split(protocol_cut, ctx),
            config::protocol_fee_recipient(),
        );
    };
    transfer::public_transfer(fee, cfg.partner_fee_claimer());
}

// === trading ===

/// Buy base with quote. The fee (per the scheduler) is skimmed off the
/// input; the last buy before graduation partial-fills to the threshold.
/// Returns (base bought, unused refund) — the caller composes what to do
/// with them (the web PTB transfers both to the sender).
public fun buy<B, Q>(
    pool: &mut VirtualPool<B, Q>,
    cfg: &PoolConfig,
    mut payment: Coin<Q>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<B>, Coin<Q>) {
    let now = assert_tradeable(pool, cfg, clock);
    let total = payment.value();
    assert!(total > 0, E_ZERO_AMOUNT);

    let fee_num = config::current_fee_num(cfg, pool.activation_ms, now, pool.swap_count == 0);
    let fee = math::fee_amount(total, fee_num, config::fee_denom());
    let net = total - fee;
    assert!(net > 0, E_ZERO_AMOUNT);

    // Partial fill: never take more quote than the threshold has room for.
    let capacity = cfg.migration_quote_threshold() - pool.quote_reserve.value();
    let (quote_used, fee_taken) = if (net > capacity) {
        // Refund the unused net AND its proportional fee.
        let fee_on_used = math::fee_amount(capacity, fee_num, config::fee_denom());
        (capacity, fee_on_used)
    } else {
        (net, fee)
    };
    assert!(quote_used > 0, E_ZERO_AMOUNT);

    let (base_out, sqrt_after) = config::quote_to_base(cfg, pool.sqrt_price, quote_used);
    assert!(base_out >= min_base_out && base_out > 0, E_SLIPPAGE);

    // Move coins: fee → waterfall buckets, used quote → reserve; whatever
    // remains in `payment` is the refund returned to the caller.
    take_fee(pool, cfg, &mut payment, fee_taken, ctx);
    pool.quote_reserve.join(payment.split(quote_used, ctx).into_balance());
    let base_out_coin = coin::take(&mut pool.base_reserve, base_out, ctx);

    pool.sqrt_price = sqrt_after;
    pool.swap_count = pool.swap_count + 1;

    let reserve_after = pool.quote_reserve.value();
    let (p, pa, c) = config::split_trading_fee(cfg, fee_taken);
    event::emit(Swap {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        is_buy: true,
        amount_in: quote_used + fee_taken,
        amount_out: base_out,
        fee: fee_taken,
        protocol_fee: p,
        partner_fee: pa,
        creator_fee: c,
        sqrt_price_after: sqrt_after,
        quote_reserve_after: reserve_after,
        timestamp_ms: now,
    });

    if (reserve_after >= cfg.migration_quote_threshold()) {
        pool.is_completed = true;
        pool.finish_ms = now;
        event::emit(CurveComplete {
            pool_id: object::id(pool),
            quote_reserve: reserve_after,
            finish_ms: now,
        });
    };

    (base_out_coin, payment)
}

/// Sell base back into the curve for quote. The fee is skimmed off the
/// quote output. Halted once the curve completes, like DBC. Returns the
/// net quote coin — the caller composes what to do with it.
public fun sell<B, Q>(
    pool: &mut VirtualPool<B, Q>,
    cfg: &PoolConfig,
    tokens: Coin<B>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Q> {
    let now = assert_tradeable(pool, cfg, clock);
    let base_in = tokens.value();
    assert!(base_in > 0, E_ZERO_AMOUNT);

    let (quote_gross, sqrt_after) = config::base_to_quote(cfg, pool.sqrt_price, base_in);
    // Belt-and-braces: the curve can never owe more than the reserve holds
    // (buy outputs round down), so this only trips on a math bug.
    assert!(quote_gross <= pool.quote_reserve.value(), E_INSOLVENT);
    assert!(quote_gross > 0, E_ZERO_AMOUNT);

    let fee_num = config::current_fee_num(cfg, pool.activation_ms, now, pool.swap_count == 0);
    let fee = math::fee_amount(quote_gross, fee_num, config::fee_denom());
    let quote_net = quote_gross - fee;
    assert!(quote_net >= min_quote_out && quote_net > 0, E_SLIPPAGE);

    pool.base_reserve.join(tokens.into_balance());
    let mut out = coin::take(&mut pool.quote_reserve, quote_gross, ctx);
    take_fee(pool, cfg, &mut out, fee, ctx);

    pool.sqrt_price = sqrt_after;
    pool.swap_count = pool.swap_count + 1;

    let (p, pa, c) = config::split_trading_fee(cfg, fee);
    event::emit(Swap {
        pool_id: object::id(pool),
        trader: ctx.sender(),
        is_buy: false,
        amount_in: base_in,
        amount_out: quote_net,
        fee,
        protocol_fee: p,
        partner_fee: pa,
        creator_fee: c,
        sqrt_price_after: sqrt_after,
        quote_reserve_after: pool.quote_reserve.value(),
        timestamp_ms: now,
    });

    out
}

fun assert_tradeable<B, Q>(
    pool: &VirtualPool<B, Q>,
    cfg: &PoolConfig,
    clock: &Clock,
): u64 {
    assert!(object::id(cfg) == pool.config_id, E_WRONG_CONFIG);
    assert!(!pool.is_completed, E_COMPLETED);
    let now = clock.timestamp_ms();
    assert!(now >= pool.activation_ms, E_NOT_ACTIVE);
    now
}

/// Split `fee` off `coin` into the three fee buckets per the waterfall.
fun take_fee<B, Q>(
    pool: &mut VirtualPool<B, Q>,
    cfg: &PoolConfig,
    coin: &mut Coin<Q>,
    fee: u64,
    ctx: &mut TxContext,
) {
    if (fee == 0) return;
    let (protocol, partner, creator) = config::split_trading_fee(cfg, fee);
    if (protocol > 0) {
        pool.fee_protocol.join(coin.split(protocol, ctx).into_balance());
    };
    if (partner > 0) {
        pool.fee_partner.join(coin.split(partner, ctx).into_balance());
    };
    if (creator > 0) {
        pool.fee_creator.join(coin.split(creator, ctx).into_balance());
    };
}

// === migration (graduation) ===

public struct Migrated has copy, drop {
    pool_id: ID,
    amm_id: ID,
    /// Seeded into the AMM.
    base_to_amm: u64,
    quote_to_amm: u64,
    /// Migration fee split into the partner/creator claim buckets.
    migration_fee_partner: u64,
    migration_fee_creator: u64,
    /// 20 bps of both migrated sides, sent to the protocol wallet.
    protocol_liq_fee_quote: u64,
    protocol_liq_fee_base: u64,
    /// Unsold buffer tokens sent to the config's leftover receiver.
    leftover_base: u64,
    timestamp_ms: u64,
}

/// Graduate a completed pool into its own AMM. Permissionless — anyone can
/// crank it (our keeper does); every payout destination is fixed by config.
///
/// Money flow, from the reserve sitting exactly on the threshold:
///   1. migration fee (`migration_fee_pct` of the threshold) → partner and
///      creator claim buckets, split by `creator_migration_fee_pct`
///   2. 20 bps of the remaining quote AND of the base headed to the AMM →
///      protocol wallet (DBC's protocol liquidity fee); taking the same bps
///      off both sides preserves the price exactly
///   3. everything else seeds the AmmPool at the curve's final price
///   4. remaining base (the unused sell-back buffer) → leftover receiver
public fun migrate<B, Q>(
    pool: &mut VirtualPool<B, Q>,
    cfg: &PoolConfig,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(object::id(cfg) == pool.config_id, E_WRONG_CONFIG);
    assert!(pool.is_completed, E_NOT_COMPLETED);
    assert!(!pool.is_migrated, E_ALREADY_MIGRATED);
    pool.is_migrated = true;

    // 1. migration fee off the top of the reserve
    let migration_fee =
        pool.quote_reserve.value() * cfg.migration_fee_pct() / 100;
    let creator_cut = migration_fee * cfg.creator_migration_fee_pct() / 100;
    let partner_cut = migration_fee - creator_cut;
    if (creator_cut > 0) {
        pool.fee_creator.join(pool.quote_reserve.split(creator_cut));
    };
    if (partner_cut > 0) {
        pool.fee_partner.join(pool.quote_reserve.split(partner_cut));
    };

    // 2. protocol liquidity fee: same bps off both sides keeps the price
    let bps = config::protocol_migration_liq_fee_bps();
    let protocol_recipient = config::protocol_fee_recipient();
    let quote_remaining = pool.quote_reserve.value();
    let proto_quote = quote_remaining * bps / 10_000;
    if (proto_quote > 0) {
        transfer::public_transfer(
            coin::take(&mut pool.quote_reserve, proto_quote, ctx),
            protocol_recipient,
        );
    };
    let base_for_amm_gross = if (cfg.migration_base_amount() < pool.base_reserve.value()) {
        cfg.migration_base_amount()
    } else {
        pool.base_reserve.value()
    };
    let proto_base = base_for_amm_gross * bps / 10_000;
    if (proto_base > 0) {
        transfer::public_transfer(
            coin::take(&mut pool.base_reserve, proto_base, ctx),
            protocol_recipient,
        );
    };
    let base_to_amm = base_for_amm_gross - proto_base;
    let quote_to_amm = pool.quote_reserve.value();

    // 3. seed the graduated AMM with everything that remains quote-side
    let amm_id = amm::create<B, Q>(
        object::id(pool),
        pool.base_reserve.split(base_to_amm),
        pool.quote_reserve.withdraw_all(),
        cfg.amm_fee_num(),
        cfg.creator_lp_fee_pct(),
        cfg.partner_fee_claimer(),
        pool.creator,
        clock,
        ctx,
    );

    // 4. leftover (unused sell-back buffer) to the fixed receiver
    let leftover_base = pool.base_reserve.value();
    if (leftover_base > 0) {
        transfer::public_transfer(
            coin::take(&mut pool.base_reserve, leftover_base, ctx),
            cfg.leftover_receiver(),
        );
    };

    event::emit(Migrated {
        pool_id: object::id(pool),
        amm_id,
        base_to_amm,
        quote_to_amm,
        migration_fee_partner: partner_cut,
        migration_fee_creator: creator_cut,
        protocol_liq_fee_quote: proto_quote,
        protocol_liq_fee_base: proto_base,
        leftover_base,
        timestamp_ms: clock.timestamp_ms(),
    });
    amm_id
}

// === fee claims — permissionless, fixed destinations ===

public fun claim_protocol_fee<B, Q>(pool: &mut VirtualPool<B, Q>, ctx: &mut TxContext) {
    let amount = pool.fee_protocol.value();
    if (amount == 0) return;
    let recipient = config::protocol_fee_recipient();
    transfer::public_transfer(coin::take(&mut pool.fee_protocol, amount, ctx), recipient);
    event::emit(FeesClaimed { pool_id: object::id(pool), kind: 0, amount, recipient });
}

public fun claim_partner_fee<B, Q>(
    pool: &mut VirtualPool<B, Q>,
    cfg: &PoolConfig,
    ctx: &mut TxContext,
) {
    assert!(object::id(cfg) == pool.config_id, E_WRONG_CONFIG);
    let amount = pool.fee_partner.value();
    if (amount == 0) return;
    let recipient = cfg.partner_fee_claimer();
    transfer::public_transfer(coin::take(&mut pool.fee_partner, amount, ctx), recipient);
    event::emit(FeesClaimed { pool_id: object::id(pool), kind: 1, amount, recipient });
}

public fun claim_creator_fee<B, Q>(pool: &mut VirtualPool<B, Q>, ctx: &mut TxContext) {
    let amount = pool.fee_creator.value();
    if (amount == 0) return;
    let recipient = pool.creator;
    transfer::public_transfer(coin::take(&mut pool.fee_creator, amount, ctx), recipient);
    event::emit(FeesClaimed { pool_id: object::id(pool), kind: 2, amount, recipient });
}

// === getters ===

public fun sqrt_price<B, Q>(pool: &VirtualPool<B, Q>): u128 { pool.sqrt_price }

public fun quote_reserve_value<B, Q>(pool: &VirtualPool<B, Q>): u64 {
    pool.quote_reserve.value()
}

public fun base_reserve_value<B, Q>(pool: &VirtualPool<B, Q>): u64 {
    pool.base_reserve.value()
}

public fun is_completed<B, Q>(pool: &VirtualPool<B, Q>): bool { pool.is_completed }

public fun is_migrated<B, Q>(pool: &VirtualPool<B, Q>): bool { pool.is_migrated }

public fun creator<B, Q>(pool: &VirtualPool<B, Q>): address { pool.creator }

public fun swap_count<B, Q>(pool: &VirtualPool<B, Q>): u64 { pool.swap_count }

public fun activation_ms<B, Q>(pool: &VirtualPool<B, Q>): u64 { pool.activation_ms }

public fun fee_accruals<B, Q>(pool: &VirtualPool<B, Q>): (u64, u64, u64) {
    (pool.fee_protocol.value(), pool.fee_partner.value(), pool.fee_creator.value())
}

public fun pool_count(registry: &Registry): u64 { registry.pool_count }

// === test-only ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx)
}

#[test_only]
public fun protocol_fee_recipient_for_testing(): address {
    config::protocol_fee_recipient()
}
