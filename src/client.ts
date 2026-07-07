// MentaraClient: a single client instantiated with a Sui client and your
// deployment addresses, exposing namespaced modules the same way Meteora's
// Dynamic Bonding Curve SDK does: client.partner, client.pool, client.creator,
// client.migration, client.state. The standalone functions remain exported
// too, for callers who prefer them.
import type { SuiClient } from '@mysten/sui/client';
import type { Transaction } from '@mysten/sui/transactions';
import type {
  CreateConfigParams,
  LaunchConfig,
  MentaraAddresses,
  PoolState,
  Venue,
} from './types.js';
import { getAmmState, getLaunchConfig, getPoolState } from './read.js';
import {
  buildBuyTx,
  buildClaimCreatorFeeTx,
  buildClaimPartnerFeeTx,
  buildCreateConfigTx,
  buildCreatePoolTx,
  buildMigrateTx,
  buildSellTx,
} from './tx.js';
import {
  buildPublishCoinTx,
  coinTypeFor,
  patchCoinBytecode,
  type CoinMetadata,
  type CoinTemplate,
} from './coin.js';
import {
  ammBaseOut,
  ammQuoteOut,
  ceilFeeRaw,
  currentFeeNum,
  curveBaseOut,
  curveQuoteOut,
  priceFromSqrt,
} from './math.js';

export interface SwapQuote {
  /** Raw output: base tokens for a buy, quote for a sell (net of fee). */
  amountOut: bigint;
  feeRaw: bigint;
  feeNum: number;
}

const DEFAULT_SLIPPAGE_BPS = 500n; // 5%
const withSlippage = (amount: bigint, bps = DEFAULT_SLIPPAGE_BPS) =>
  (amount * (10_000n - bps)) / 10_000n;

/** client.state: read live on-chain state. */
class StateModule {
  constructor(
    private readonly sui: SuiClient,
    private readonly addr: MentaraAddresses,
  ) {}

  getPool(poolId: string): Promise<PoolState> {
    return getPoolState(this.sui, poolId);
  }
  getAmm(ammId: string): Promise<PoolState> {
    return getAmmState(this.sui, ammId);
  }
  getConfig(configId: string): Promise<LaunchConfig> {
    return getLaunchConfig(this.sui, configId);
  }

  /** Fraction 0..1 of the graduation threshold the curve has raised. */
  async getCurveProgress(poolId: string): Promise<number> {
    const [state] = [await getPoolState(this.sui, poolId)];
    if (!state.configId) return 1;
    const cfg = await getLaunchConfig(this.sui, state.configId);
    if (cfg.thresholdRaw === 0n) return 0;
    return Math.min(Number(state.quoteReserve) / Number(cfg.thresholdRaw), 1);
  }
}

/** client.pool: trading and quoting. */
class PoolModule {
  constructor(
    private readonly sui: SuiClient,
    private readonly addr: MentaraAddresses,
  ) {}

  /** Exact output quote for a buy or sell, fee included. Needs the config for
   *  curve trades (segment walk); AMM uses reserves. */
  swapQuote(args: {
    state: PoolState;
    config?: LaunchConfig;
    amountInRaw: bigint;
    isBuy: boolean;
    nowMs?: number;
  }): SwapQuote {
    const { state, config, amountInRaw, isBuy } = args;
    const feeNum =
      state.venue === 'amm'
        ? state.feeNum
        : config
          ? currentFeeNum(config, state.activationMs, args.nowMs ?? Date.now(), state.swapCount === 0)
          : 0;
    if (isBuy) {
      const net = amountInRaw - ceilFeeRaw(amountInRaw, feeNum);
      const feeRaw = amountInRaw - net;
      if (net <= 0n) return { amountOut: 0n, feeRaw, feeNum };
      if (state.venue === 'amm') {
        return { amountOut: ammBaseOut(state.baseReserve, state.quoteReserve, net), feeRaw, feeNum };
      }
      if (!config) throw new Error('config required to quote a curve buy');
      const capacity = Number(config.thresholdRaw - state.quoteReserve);
      const out = curveBaseOut(config.segments, state.sqrtPrice, Number(net), capacity);
      return { amountOut: BigInt(Math.floor(out)), feeRaw, feeNum };
    }
    // sell
    let gross: bigint;
    if (state.venue === 'amm') {
      gross = ammQuoteOut(state.baseReserve, state.quoteReserve, amountInRaw);
    } else {
      if (!config) throw new Error('config required to quote a curve sell');
      gross = BigInt(Math.floor(curveQuoteOut(config.segments, state.sqrtPrice, Number(amountInRaw))));
    }
    const feeRaw = ceilFeeRaw(gross, feeNum);
    return { amountOut: gross - feeRaw, feeRaw, feeNum };
  }

  /** Current spot price (quote per whole token). */
  spotPrice(state: PoolState): number {
    return state.venue === 'amm'
      ? state.baseReserve === 0n
        ? 0
        : Number(state.quoteReserve) / Number(state.baseReserve)
      : priceFromSqrt(state.sqrtPrice);
  }

  buy(args: {
    sender: string;
    venue: Venue;
    poolOrAmmId: string;
    configId: string | null;
    coinType: string;
    quoteType: string;
    amountRaw: bigint;
    minTokensRaw: bigint;
  }): Promise<Transaction> {
    return buildBuyTx({ addr: this.addr, client: this.sui, ...args });
  }

  sell(args: {
    sender: string;
    venue: Venue;
    poolOrAmmId: string;
    configId: string | null;
    coinType: string;
    quoteType: string;
    tokenRaw: bigint;
    minQuoteRaw: bigint;
  }): Promise<Transaction> {
    return buildSellTx({ addr: this.addr, client: this.sui, ...args });
  }

  /** Convenience: quote then build a buy with a slippage floor in one call. */
  async buyWithSlippage(args: {
    sender: string;
    poolOrAmmId: string;
    state: PoolState;
    config?: LaunchConfig;
    coinType: string;
    quoteType: string;
    amountRaw: bigint;
    slippageBps?: bigint;
  }): Promise<Transaction> {
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
  constructor(
    private readonly sui: SuiClient,
    private readonly addr: MentaraAddresses,
  ) {}

  createConfig(params: CreateConfigParams): Transaction {
    return buildCreateConfigTx(this.addr, params);
  }
  claimTradingFee(args: {
    sender: string;
    coinType: string;
    quoteType: string;
    poolId?: string | null;
    configId?: string | null;
    ammId?: string | null;
  }): Transaction {
    return buildClaimPartnerFeeTx({ addr: this.addr, ...args });
  }
}

/** client.creator: token creator actions (publish coin, open pool, claim). */
class CreatorModule {
  constructor(
    private readonly sui: SuiClient,
    private readonly addr: MentaraAddresses,
  ) {}

  /** Patch + publish a coin. Sign with a funded publisher; the created
   *  TreasuryCap then goes to createPool, which locks it. */
  publishCoin(template: CoinTemplate, meta: CoinMetadata): Transaction {
    return buildPublishCoinTx(patchCoinBytecode(template, meta), template.dependencies);
  }
  coinType(packageId: string, ticker: string): string {
    return coinTypeFor(packageId, ticker);
  }
  createPool(args: {
    configId: string;
    treasuryCapId: string;
    creator: string;
    coinType: string;
    quoteType: string;
  }): Transaction {
    return buildCreatePoolTx({ addr: this.addr, ...args });
  }
  claimTradingFee(args: {
    sender: string;
    coinType: string;
    quoteType: string;
    poolId?: string | null;
    ammId?: string | null;
  }): Transaction {
    return buildClaimCreatorFeeTx({ addr: this.addr, ...args });
  }
}

/** client.migration: graduate a completed curve into its AMM. */
class MigrationModule {
  constructor(
    private readonly sui: SuiClient,
    private readonly addr: MentaraAddresses,
  ) {}

  migrate(args: {
    poolId: string;
    configId: string;
    coinType: string;
    quoteType: string;
  }): Transaction {
    return buildMigrateTx({ addr: this.addr, ...args });
  }
}

export class MentaraClient {
  readonly state: StateModule;
  readonly pool: PoolModule;
  readonly partner: PartnerModule;
  readonly creator: CreatorModule;
  readonly migration: MigrationModule;

  constructor(
    readonly sui: SuiClient,
    readonly addresses: MentaraAddresses,
  ) {
    this.state = new StateModule(sui, addresses);
    this.pool = new PoolModule(sui, addresses);
    this.partner = new PartnerModule(sui, addresses);
    this.creator = new CreatorModule(sui, addresses);
    this.migration = new MigrationModule(sui, addresses);
  }
}
