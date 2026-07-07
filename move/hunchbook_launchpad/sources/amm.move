// AmmPool — the graduation venue (our Meteora-DAMM / PumpSwap equivalent).
// A plain constant-product (x·y=k) pool seeded once, at migration, with the
// bonding curve's proceeds at exactly the curve's final price.
//
// Deliberate simplifications vs a general-purpose DEX:
//   - liquidity is seeded once by `create` (package-only) and is PERMANENTLY
//     LOCKED — there is no add/remove-liquidity surface at all, so the
//     "locked LP" guarantee is structural, not a promise
//   - fees are collected quote-side only (same convention as the curve) and
//     split by the same 20/40/40 waterfall: protocol / partner / creator
//   - claims are permissionless with fixed destinations, like the curve's
module hunchbook_launchpad::amm;

use hunchbook_launchpad::config;
use hunchbook_launchpad::math;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;

const E_ZERO_AMOUNT: u64 = 300;
const E_SLIPPAGE: u64 = 301;
const E_EMPTY_RESERVE: u64 = 302;

public struct AmmPool<phantom B, phantom Q> has key {
    id: UID,
    /// The bonding-curve pool this AMM graduated from.
    source_pool: ID,
    base_reserve: Balance<B>,
    quote_reserve: Balance<Q>,
    /// Trading fee over config::fee_denom(), copied from the config.
    fee_num: u64,
    /// Creator's share of the LP fee (the 80% after protocol), copied.
    creator_lp_fee_pct: u64,
    partner_fee_claimer: address,
    creator: address,
    fee_protocol: Balance<Q>,
    fee_partner: Balance<Q>,
    fee_creator: Balance<Q>,
}

public struct AmmPoolCreated has copy, drop {
    amm_id: ID,
    source_pool: ID,
    base_reserve: u64,
    quote_reserve: u64,
    fee_num: u64,
    timestamp_ms: u64,
}

public struct AmmSwap has copy, drop {
    amm_id: ID,
    trader: address,
    is_buy: bool,
    amount_in: u64,
    amount_out: u64,
    fee: u64,
    protocol_fee: u64,
    partner_fee: u64,
    creator_fee: u64,
    base_reserve_after: u64,
    quote_reserve_after: u64,
    timestamp_ms: u64,
}

public struct AmmFeesClaimed has copy, drop {
    amm_id: ID,
    /// 0 = protocol, 1 = partner, 2 = creator
    kind: u8,
    amount: u64,
    recipient: address,
}

/// Seed and share the graduated pool. Only callable from this package
/// (pool::migrate) — there is no public way to create or fund an AmmPool.
public(package) fun create<B, Q>(
    source_pool: ID,
    base_reserve: Balance<B>,
    quote_reserve: Balance<Q>,
    fee_num: u64,
    creator_lp_fee_pct: u64,
    partner_fee_claimer: address,
    creator: address,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(base_reserve.value() > 0 && quote_reserve.value() > 0, E_EMPTY_RESERVE);
    let pool = AmmPool<B, Q> {
        id: object::new(ctx),
        source_pool,
        base_reserve,
        quote_reserve,
        fee_num,
        creator_lp_fee_pct,
        partner_fee_claimer,
        creator,
        fee_protocol: sui::balance::zero(),
        fee_partner: sui::balance::zero(),
        fee_creator: sui::balance::zero(),
    };
    let amm_id = object::id(&pool);
    event::emit(AmmPoolCreated {
        amm_id,
        source_pool,
        base_reserve: pool.base_reserve.value(),
        quote_reserve: pool.quote_reserve.value(),
        fee_num,
        timestamp_ms: clock.timestamp_ms(),
    });
    transfer::share_object(pool);
    amm_id
}

/// Buy base with quote: x·y=k on the net amount, fee skimmed off the input.
/// Returns the base bought — the caller composes delivery.
public fun buy<B, Q>(
    pool: &mut AmmPool<B, Q>,
    mut payment: Coin<Q>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<B> {
    let total = payment.value();
    assert!(total > 0, E_ZERO_AMOUNT);
    let fee = math::fee_amount(total, pool.fee_num, config::fee_denom());
    let net = total - fee;
    assert!(net > 0, E_ZERO_AMOUNT);

    let base_r = pool.base_reserve.value() as u128;
    let quote_r = pool.quote_reserve.value() as u128;
    let base_out = ((base_r * (net as u128)) / (quote_r + (net as u128))) as u64;
    assert!(base_out >= min_base_out && base_out > 0, E_SLIPPAGE);

    let (p, pa, c) = take_fee(pool, &mut payment, fee, ctx);
    pool.quote_reserve.join(payment.into_balance());
    let out = coin::take(&mut pool.base_reserve, base_out, ctx);

    event::emit(AmmSwap {
        amm_id: object::id(pool),
        trader: ctx.sender(),
        is_buy: true,
        amount_in: total,
        amount_out: base_out,
        fee,
        protocol_fee: p,
        partner_fee: pa,
        creator_fee: c,
        base_reserve_after: pool.base_reserve.value(),
        quote_reserve_after: pool.quote_reserve.value(),
        timestamp_ms: clock.timestamp_ms(),
    });
    out
}

/// Sell base for quote: x·y=k, fee skimmed off the quote output.
public fun sell<B, Q>(
    pool: &mut AmmPool<B, Q>,
    tokens: Coin<B>,
    min_quote_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Q> {
    let base_in = tokens.value();
    assert!(base_in > 0, E_ZERO_AMOUNT);

    let base_r = pool.base_reserve.value() as u128;
    let quote_r = pool.quote_reserve.value() as u128;
    let quote_gross = ((quote_r * (base_in as u128)) / (base_r + (base_in as u128))) as u64;
    assert!(quote_gross > 0, E_ZERO_AMOUNT);

    let fee = math::fee_amount(quote_gross, pool.fee_num, config::fee_denom());
    let quote_net = quote_gross - fee;
    assert!(quote_net >= min_quote_out && quote_net > 0, E_SLIPPAGE);

    pool.base_reserve.join(tokens.into_balance());
    let mut out = coin::take(&mut pool.quote_reserve, quote_gross, ctx);
    let (p, pa, c) = take_fee(pool, &mut out, fee, ctx);

    event::emit(AmmSwap {
        amm_id: object::id(pool),
        trader: ctx.sender(),
        is_buy: false,
        amount_in: base_in,
        amount_out: quote_net,
        fee,
        protocol_fee: p,
        partner_fee: pa,
        creator_fee: c,
        base_reserve_after: pool.base_reserve.value(),
        quote_reserve_after: pool.quote_reserve.value(),
        timestamp_ms: clock.timestamp_ms(),
    });
    out
}

fun take_fee<B, Q>(
    pool: &mut AmmPool<B, Q>,
    coin: &mut Coin<Q>,
    fee: u64,
    ctx: &mut TxContext,
): (u64, u64, u64) {
    if (fee == 0) return (0, 0, 0);
    let (protocol, partner, creator) = config::split_fee(fee, pool.creator_lp_fee_pct);
    if (protocol > 0) {
        pool.fee_protocol.join(coin.split(protocol, ctx).into_balance());
    };
    if (partner > 0) {
        pool.fee_partner.join(coin.split(partner, ctx).into_balance());
    };
    if (creator > 0) {
        pool.fee_creator.join(coin.split(creator, ctx).into_balance());
    };
    (protocol, partner, creator)
}

// === fee claims — permissionless, fixed destinations ===

public fun claim_protocol_fee<B, Q>(pool: &mut AmmPool<B, Q>, ctx: &mut TxContext) {
    let amount = pool.fee_protocol.value();
    if (amount == 0) return;
    let recipient = config::protocol_fee_recipient();
    transfer::public_transfer(coin::take(&mut pool.fee_protocol, amount, ctx), recipient);
    event::emit(AmmFeesClaimed { amm_id: object::id(pool), kind: 0, amount, recipient });
}

public fun claim_partner_fee<B, Q>(pool: &mut AmmPool<B, Q>, ctx: &mut TxContext) {
    let amount = pool.fee_partner.value();
    if (amount == 0) return;
    let recipient = pool.partner_fee_claimer;
    transfer::public_transfer(coin::take(&mut pool.fee_partner, amount, ctx), recipient);
    event::emit(AmmFeesClaimed { amm_id: object::id(pool), kind: 1, amount, recipient });
}

public fun claim_creator_fee<B, Q>(pool: &mut AmmPool<B, Q>, ctx: &mut TxContext) {
    let amount = pool.fee_creator.value();
    if (amount == 0) return;
    let recipient = pool.creator;
    transfer::public_transfer(coin::take(&mut pool.fee_creator, amount, ctx), recipient);
    event::emit(AmmFeesClaimed { amm_id: object::id(pool), kind: 2, amount, recipient });
}

// === getters ===

public fun reserves<B, Q>(pool: &AmmPool<B, Q>): (u64, u64) {
    (pool.base_reserve.value(), pool.quote_reserve.value())
}

public fun fee_accruals<B, Q>(pool: &AmmPool<B, Q>): (u64, u64, u64) {
    (pool.fee_protocol.value(), pool.fee_partner.value(), pool.fee_creator.value())
}

public fun source_pool<B, Q>(pool: &AmmPool<B, Q>): ID { pool.source_pool }

public fun creator<B, Q>(pool: &AmmPool<B, Q>): address { pool.creator }
