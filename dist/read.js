const TWO64 = 2 ** 64;
// Balance<T> serializes as a raw string or a { value } struct; handle both.
function readBalance(field) {
    if (typeof field === 'string')
        return BigInt(field);
    if (field && typeof field === 'object' && 'value' in field) {
        return BigInt(String(field.value));
    }
    return 0n;
}
async function fields(client, id) {
    const obj = await client.getObject({ id, options: { showContent: true } });
    const f = obj.data?.content?.fields;
    if (!f)
        throw new Error(`object ${id} unreadable`);
    return f;
}
/** Read a bonding-curve VirtualPool's live state. */
export async function getPoolState(client, poolId) {
    const f = await fields(client, poolId);
    return {
        venue: 'curve',
        configId: String(f.config_id),
        sqrtPrice: BigInt(String(f.sqrt_price)),
        baseReserve: readBalance(f.base_reserve),
        quoteReserve: readBalance(f.quote_reserve),
        activationMs: Number(f.activation_ms),
        swapCount: Number(f.swap_count),
        isCompleted: Boolean(f.is_completed),
        feeNum: 0,
        creatorFeesRaw: readBalance(f.fee_creator),
        partnerFeesRaw: readBalance(f.fee_partner),
    };
}
/** Read a graduated AmmPool's reserves and fee state. */
export async function getAmmState(client, ammId) {
    const f = await fields(client, ammId);
    return {
        venue: 'amm',
        configId: null,
        sqrtPrice: 0n,
        baseReserve: readBalance(f.base_reserve),
        quoteReserve: readBalance(f.quote_reserve),
        activationMs: 0,
        swapCount: 0,
        isCompleted: false,
        feeNum: Number(f.fee_num),
        creatorFeesRaw: readBalance(f.fee_creator),
        partnerFeesRaw: readBalance(f.fee_partner),
    };
}
/** Read an immutable launch config: quote, threshold, scheduler, curve. */
export async function getLaunchConfig(client, configId) {
    const f = await fields(client, configId);
    const quoteName = String(f.quote_type.fields.name);
    const quoteType = quoteName.startsWith('0x') ? quoteName : `0x${quoteName}`;
    const start = Number(BigInt(String(f.sqrt_start_price))) / TWO64;
    const pts = f.curve.map((p) => ({
        sqrt: Number(BigInt(p.fields.sqrt_price)) / TWO64,
        liq: Number(BigInt(p.fields.liquidity)),
    }));
    const segments = pts.map((p, i) => ({
        lower: i === 0 ? start : pts[i - 1].sqrt,
        upper: p.sqrt,
        liquidity: p.liq,
    }));
    return {
        quoteType,
        thresholdRaw: BigInt(String(f.migration_quote_threshold)),
        feeMode: Number(f.fee_mode),
        cliffFeeNum: Number(f.cliff_fee_num),
        periodMs: Number(f.period_freq_ms),
        feeReduction: Number(f.fee_reduction),
        nPeriods: Number(f.n_periods),
        firstSwapMinFee: Boolean(f.first_swap_min_fee),
        ammFeeNum: Number(f.amm_fee_num),
        segments,
    };
}
