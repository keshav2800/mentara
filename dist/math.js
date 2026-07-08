// Pure curve, fee, and AMM math. No chain client, no framework. This is the
// canonical pricing engine any Mentara integrator uses to quote and size
// trades. Every formula mirrors the on-chain Move code exactly.
//
// sigma (σ) = sqrt_price_raw / 2^64 (the real square-root price). In σ-space:
//   quote_raw = L·(σb − σa)                 (the 2^64 factor cancels)
//   base_raw  = L·(σb − σa) / (σa·σb)        (both 2^64 factors cancel)
//   σ after paying quote q at L:  σ + q/L
//   σ after selling base b at L:  σ·L / (L + b·σ)
export const FEE_DENOM = 1_000_000_000;
export const MIN_FEE_NUM = 2_500_000; // 25 bps floor
const TWO64 = 2 ** 64;
/** Trading-fee numerator in force at `nowMs` (mirror of config::current_fee_num). */
export function currentFeeNum(s, activationMs, nowMs, isFirstSwap) {
    if (isFirstSwap && s.firstSwapMinFee)
        return MIN_FEE_NUM;
    if (s.feeMode === 0)
        return s.cliffFeeNum;
    const elapsed = Math.max(0, nowMs - activationMs);
    const n = Math.min(Math.floor(elapsed / s.periodMs), s.nPeriods);
    if (s.feeMode === 1)
        return s.cliffFeeNum - s.feeReduction * n;
    let fee = s.cliffFeeNum;
    for (let i = 0; i < n; i++)
        fee = Math.floor((fee * (10_000 - s.feeReduction)) / 10_000);
    return fee;
}
/** ceil(amount · feeNum / denom) — fee rounding favours the pool. */
export function ceilFeeRaw(amountRaw, feeNum) {
    return (amountRaw * BigInt(feeNum) + BigInt(FEE_DENOM - 1)) / BigInt(FEE_DENOM);
}
/** Spot price (quote per whole token) from a raw sqrt price. */
export function priceFromSqrt(sqrtRaw) {
    const p = Number(sqrtRaw) / TWO64;
    return p * p;
}
/** Base tokens out for `netQuoteRaw`, walking up from `sqrtRaw`, capped at
 *  `capacityRaw` (partial-fill at the graduation threshold). Raw base units. */
export function curveBaseOut(segments, sqrtRaw, netQuoteRaw, capacityRaw) {
    let sigma = Number(sqrtRaw) / TWO64;
    let remaining = Math.min(netQuoteRaw, capacityRaw);
    let baseOut = 0;
    for (const s of segments) {
        if (remaining <= 0)
            break;
        if (s.upper <= sigma)
            continue;
        const dqBand = s.liquidity * (s.upper - sigma);
        if (remaining < dqBand) {
            const sNew = sigma + remaining / s.liquidity;
            baseOut += (s.liquidity * (sNew - sigma)) / (sigma * sNew);
            sigma = sNew;
            remaining = 0;
        }
        else {
            baseOut += (s.liquidity * (s.upper - sigma)) / (sigma * s.upper);
            remaining -= dqBand;
            sigma = s.upper;
        }
    }
    return baseOut;
}
/** Gross quote out for selling `baseInRaw`, walking down from `sqrtRaw`. */
export function curveQuoteOut(segments, sqrtRaw, baseInRaw) {
    let sigma = Number(sqrtRaw) / TWO64;
    let remaining = baseInRaw;
    let quoteOut = 0;
    for (let i = segments.length - 1; i >= 0 && remaining > 0; i--) {
        const s = segments[i];
        if (s.lower >= sigma)
            continue;
        const top = Math.min(s.upper, sigma);
        if (top <= s.lower)
            continue;
        const dbBand = (s.liquidity * (top - s.lower)) / (s.lower * top);
        if (remaining < dbBand) {
            const sNew = (sigma * s.liquidity) / (s.liquidity + remaining * sigma);
            quoteOut += s.liquidity * (top - sNew);
            sigma = sNew;
            remaining = 0;
        }
        else {
            quoteOut += s.liquidity * (top - s.lower);
            remaining -= dbBand;
            sigma = s.lower;
        }
    }
    return quoteOut;
}
/** Gross quote needed to buy `baseTargetRaw` walking up from `sqrtRaw` — used
 *  for "$ ↔ % of supply" previews at launch. */
export function curveQuoteForBase(segments, sqrtRaw, baseTargetRaw) {
    let sigma = Number(sqrtRaw) / TWO64;
    let remainingBase = baseTargetRaw;
    let quote = 0;
    for (const s of segments) {
        if (remainingBase <= 0)
            break;
        if (s.upper <= sigma)
            continue;
        const segBase = (s.liquidity * (s.upper - sigma)) / (sigma * s.upper);
        if (remainingBase < segBase) {
            const sNew = sigma / (1 - (remainingBase * sigma) / s.liquidity);
            quote += s.liquidity * (sNew - sigma);
            remainingBase = 0;
        }
        else {
            quote += s.liquidity * (s.upper - sigma);
            remainingBase -= segBase;
            sigma = s.upper;
        }
    }
    return remainingBase > 0 ? Infinity : quote;
}
/** Constant-product AMM quotes (raw units). */
export function ammBaseOut(baseReserve, quoteReserve, netQuoteRaw) {
    return (baseReserve * netQuoteRaw) / (quoteReserve + netQuoteRaw);
}
export function ammQuoteOut(baseReserve, quoteReserve, tokenRaw) {
    return (quoteReserve * tokenRaw) / (baseReserve + tokenRaw);
}
/**
 * Solve a single-segment curve for a launch config from human tokenomics —
 * the Mentara equivalent of Meteora's buildCurveWithMarketCap. Returns the raw
 * sqrt_start / sqrt_end / liquidity to pass to config::create_config.
 */
export function solveSingleSegmentCurve(opts) {
    const { totalSupplyRaw, thresholdRaw, priceRun, migrationFeePct, bufferPct } = opts;
    const buffer = 1 + bufferPct / 100;
    const k = Math.sqrt(priceRun);
    const supplyCoef = buffer * (1 - 1 / k) + ((1 - migrationFeePct / 100) * (k - 1)) / priceRun;
    const A = totalSupplyRaw / supplyCoef; // L / σ0
    const B = thresholdRaw / (k - 1); //      L · σ0
    const sigma0 = Math.sqrt(B / A);
    return {
        sqrtStart: BigInt(Math.round(sigma0 * TWO64)),
        sqrtEnd: BigInt(Math.round(sigma0 * 4 * TWO64)),
        liquidity: BigInt(Math.round(Math.sqrt(A * B))),
    };
}
