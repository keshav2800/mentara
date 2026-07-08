import { getAmmState, getLaunchConfig, getPoolState } from './read.js';
import { buildBuyTx, buildClaimCreatorFeeTx, buildClaimPartnerFeeTx, buildCreateConfigTx, buildCreatePoolTx, buildMigrateTx, buildSellTx, } from './tx.js';
import { buildPublishCoinTx, coinTypeFor, patchCoinBytecode, } from './coin.js';
import { ammBaseOut, ammQuoteOut, ceilFeeRaw, currentFeeNum, curveBaseOut, curveQuoteOut, priceFromSqrt, } from './math.js';
const DEFAULT_SLIPPAGE_BPS = 500n; // 5%
const withSlippage = (amount, bps = DEFAULT_SLIPPAGE_BPS) => (amount * (10000n - bps)) / 10000n;
/** client.state: read live on-chain state. */
class StateModule {
    sui;
    addr;
    constructor(sui, addr) {
        this.sui = sui;
        this.addr = addr;
    }
    getPool(poolId) {
        return getPoolState(this.sui, poolId);
    }
    getAmm(ammId) {
        return getAmmState(this.sui, ammId);
    }
    getConfig(configId) {
        return getLaunchConfig(this.sui, configId);
    }
    /** Fraction 0..1 of the graduation threshold the curve has raised. */
    async getCurveProgress(poolId) {
        const [state] = [await getPoolState(this.sui, poolId)];
        if (!state.configId)
            return 1;
        const cfg = await getLaunchConfig(this.sui, state.configId);
        if (cfg.thresholdRaw === 0n)
            return 0;
        return Math.min(Number(state.quoteReserve) / Number(cfg.thresholdRaw), 1);
    }
}
/** client.pool: trading and quoting. */
class PoolModule {
    sui;
    addr;
    constructor(sui, addr) {
        this.sui = sui;
        this.addr = addr;
    }
    /** Exact output quote for a buy or sell, fee included. Needs the config for
     *  curve trades (segment walk); AMM uses reserves. */
    swapQuote(args) {
        const { state, config, amountInRaw, isBuy } = args;
        const feeNum = state.venue === 'amm'
            ? state.feeNum
            : config
                ? currentFeeNum(config, state.activationMs, args.nowMs ?? Date.now(), state.swapCount === 0)
                : 0;
        if (isBuy) {
            const net = amountInRaw - ceilFeeRaw(amountInRaw, feeNum);
            const feeRaw = amountInRaw - net;
            if (net <= 0n)
                return { amountOut: 0n, feeRaw, feeNum };
            if (state.venue === 'amm') {
                return { amountOut: ammBaseOut(state.baseReserve, state.quoteReserve, net), feeRaw, feeNum };
            }
            if (!config)
                throw new Error('config required to quote a curve buy');
            const capacity = Number(config.thresholdRaw - state.quoteReserve);
            const out = curveBaseOut(config.segments, state.sqrtPrice, Number(net), capacity);
            return { amountOut: BigInt(Math.floor(out)), feeRaw, feeNum };
        }
        // sell
        let gross;
        if (state.venue === 'amm') {
            gross = ammQuoteOut(state.baseReserve, state.quoteReserve, amountInRaw);
        }
        else {
            if (!config)
                throw new Error('config required to quote a curve sell');
            gross = BigInt(Math.floor(curveQuoteOut(config.segments, state.sqrtPrice, Number(amountInRaw))));
        }
        const feeRaw = ceilFeeRaw(gross, feeNum);
        return { amountOut: gross - feeRaw, feeRaw, feeNum };
    }
    /** Current spot price (quote per whole token). */
    spotPrice(state) {
        return state.venue === 'amm'
            ? state.baseReserve === 0n
                ? 0
                : Number(state.quoteReserve) / Number(state.baseReserve)
            : priceFromSqrt(state.sqrtPrice);
    }
    buy(args) {
        return buildBuyTx({ addr: this.addr, client: this.sui, ...args });
    }
    sell(args) {
        return buildSellTx({ addr: this.addr, client: this.sui, ...args });
    }
    /** Convenience: quote then build a buy with a slippage floor in one call. */
    async buyWithSlippage(args) {
        const q = this.swapQuote({ state: args.state, config: args.config, amountInRaw: args.amountRaw, isBuy: true });
        return this.buy({
            sender: args.sender,
            venue: args.state.venue,
            poolOrAmmId: args.poolOrAmmId,
            configId: args.state.configId,
            coinType: args.coinType,
            quoteType: args.quoteType,
            amountRaw: args.amountRaw,
            minTokensRaw: withSlippage(q.amountOut, args.slippageBps),
        });
    }
}
/** client.partner: launchpad operator actions (configs and partner fees). */
class PartnerModule {
    sui;
    addr;
    constructor(sui, addr) {
        this.sui = sui;
        this.addr = addr;
    }
    createConfig(params) {
        return buildCreateConfigTx(this.addr, params);
    }
    claimTradingFee(args) {
        return buildClaimPartnerFeeTx({ addr: this.addr, ...args });
    }
}
/** client.creator: token creator actions (publish coin, open pool, claim). */
class CreatorModule {
    sui;
    addr;
    constructor(sui, addr) {
        this.sui = sui;
        this.addr = addr;
    }
    /** Patch + publish a coin. Sign with a funded publisher; the created
     *  TreasuryCap then goes to createPool, which locks it. */
    publishCoin(template, meta) {
        return buildPublishCoinTx(patchCoinBytecode(template, meta), template.dependencies);
    }
    coinType(packageId, ticker) {
        return coinTypeFor(packageId, ticker);
    }
    createPool(args) {
        return buildCreatePoolTx({ addr: this.addr, ...args });
    }
    claimTradingFee(args) {
        return buildClaimCreatorFeeTx({ addr: this.addr, ...args });
    }
}
/** client.migration: graduate a completed curve into its AMM. */
class MigrationModule {
    sui;
    addr;
    constructor(sui, addr) {
        this.sui = sui;
        this.addr = addr;
    }
    migrate(args) {
        return buildMigrateTx({ addr: this.addr, ...args });
    }
}
export class MentaraClient {
    sui;
    addresses;
    state;
    pool;
    partner;
    creator;
    migration;
    constructor(sui, addresses) {
        this.sui = sui;
        this.addresses = addresses;
        this.state = new StateModule(sui, addresses);
        this.pool = new PoolModule(sui, addresses);
        this.partner = new PartnerModule(sui, addresses);
        this.creator = new CreatorModule(sui, addresses);
        this.migration = new MigrationModule(sui, addresses);
    }
}
