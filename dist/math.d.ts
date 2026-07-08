export declare const FEE_DENOM = 1000000000;
export declare const MIN_FEE_NUM = 2500000;
/** One bonding-curve segment, in σ-space. */
export interface CurveSeg {
    lower: number;
    upper: number;
    liquidity: number;
}
/** Anti-sniper fee scheduler parameters (from a PoolConfig). */
export interface FeeSchedule {
    feeMode: number;
    cliffFeeNum: number;
    periodMs: number;
    feeReduction: number;
    nPeriods: number;
    firstSwapMinFee: boolean;
}
/** Trading-fee numerator in force at `nowMs` (mirror of config::current_fee_num). */
export declare function currentFeeNum(s: FeeSchedule, activationMs: number, nowMs: number, isFirstSwap: boolean): number;
/** ceil(amount · feeNum / denom) — fee rounding favours the pool. */
export declare function ceilFeeRaw(amountRaw: bigint, feeNum: number): bigint;
/** Spot price (quote per whole token) from a raw sqrt price. */
export declare function priceFromSqrt(sqrtRaw: bigint): number;
/** Base tokens out for `netQuoteRaw`, walking up from `sqrtRaw`, capped at
 *  `capacityRaw` (partial-fill at the graduation threshold). Raw base units. */
export declare function curveBaseOut(segments: CurveSeg[], sqrtRaw: bigint, netQuoteRaw: number, capacityRaw: number): number;
/** Gross quote out for selling `baseInRaw`, walking down from `sqrtRaw`. */
export declare function curveQuoteOut(segments: CurveSeg[], sqrtRaw: bigint, baseInRaw: number): number;
/** Gross quote needed to buy `baseTargetRaw` walking up from `sqrtRaw` — used
 *  for "$ ↔ % of supply" previews at launch. */
export declare function curveQuoteForBase(segments: CurveSeg[], sqrtRaw: bigint, baseTargetRaw: number): number;
/** Constant-product AMM quotes (raw units). */
export declare function ammBaseOut(baseReserve: bigint, quoteReserve: bigint, netQuoteRaw: bigint): bigint;
export declare function ammQuoteOut(baseReserve: bigint, quoteReserve: bigint, tokenRaw: bigint): bigint;
/**
 * Solve a single-segment curve for a launch config from human tokenomics —
 * the Mentara equivalent of Meteora's buildCurveWithMarketCap. Returns the raw
 * sqrt_start / sqrt_end / liquidity to pass to config::create_config.
 */
export declare function solveSingleSegmentCurve(opts: {
    totalSupplyRaw: number;
    thresholdRaw: number;
    priceRun: number;
    migrationFeePct: number;
    bufferPct: number;
}): {
    sqrtStart: bigint;
    sqrtEnd: bigint;
    liquidity: bigint;
};
