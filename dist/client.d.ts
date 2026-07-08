import type { SuiClient } from '@mysten/sui/client';
import type { Transaction } from '@mysten/sui/transactions';
import type { CreateConfigParams, LaunchConfig, MentaraAddresses, PoolState, Venue } from './types.js';
import { type CoinMetadata, type CoinTemplate } from './coin.js';
export interface SwapQuote {
    /** Raw output: base tokens for a buy, quote for a sell (net of fee). */
    amountOut: bigint;
    feeRaw: bigint;
    feeNum: number;
}
/** client.state: read live on-chain state. */
declare class StateModule {
    private readonly sui;
    private readonly addr;
    constructor(sui: SuiClient, addr: MentaraAddresses);
    getPool(poolId: string): Promise<PoolState>;
    getAmm(ammId: string): Promise<PoolState>;
    getConfig(configId: string): Promise<LaunchConfig>;
    /** Fraction 0..1 of the graduation threshold the curve has raised. */
    getCurveProgress(poolId: string): Promise<number>;
}
/** client.pool: trading and quoting. */
declare class PoolModule {
    private readonly sui;
    private readonly addr;
    constructor(sui: SuiClient, addr: MentaraAddresses);
    /** Exact output quote for a buy or sell, fee included. Needs the config for
     *  curve trades (segment walk); AMM uses reserves. */
    swapQuote(args: {
        state: PoolState;
        config?: LaunchConfig;
        amountInRaw: bigint;
        isBuy: boolean;
        nowMs?: number;
    }): SwapQuote;
    /** Current spot price (quote per whole token). */
    spotPrice(state: PoolState): number;
    buy(args: {
        sender: string;
        venue: Venue;
        poolOrAmmId: string;
        configId: string | null;
        coinType: string;
        quoteType: string;
        amountRaw: bigint;
        minTokensRaw: bigint;
    }): Promise<Transaction>;
    sell(args: {
        sender: string;
        venue: Venue;
        poolOrAmmId: string;
        configId: string | null;
        coinType: string;
        quoteType: string;
        tokenRaw: bigint;
        minQuoteRaw: bigint;
    }): Promise<Transaction>;
    /** Convenience: quote then build a buy with a slippage floor in one call. */
    buyWithSlippage(args: {
        sender: string;
        poolOrAmmId: string;
        state: PoolState;
        config?: LaunchConfig;
        coinType: string;
        quoteType: string;
        amountRaw: bigint;
        slippageBps?: bigint;
    }): Promise<Transaction>;
}
/** client.partner: launchpad operator actions (configs and partner fees). */
declare class PartnerModule {
    private readonly sui;
    private readonly addr;
    constructor(sui: SuiClient, addr: MentaraAddresses);
    createConfig(params: CreateConfigParams): Transaction;
    claimTradingFee(args: {
        sender: string;
        coinType: string;
        quoteType: string;
        poolId?: string | null;
        configId?: string | null;
        ammId?: string | null;
    }): Transaction;
}
/** client.creator: token creator actions (publish coin, open pool, claim). */
declare class CreatorModule {
    private readonly sui;
    private readonly addr;
    constructor(sui: SuiClient, addr: MentaraAddresses);
    /** Patch + publish a coin. Sign with a funded publisher; the created
     *  TreasuryCap then goes to createPool, which locks it. */
    publishCoin(template: CoinTemplate, meta: CoinMetadata): Transaction;
    coinType(packageId: string, ticker: string): string;
    createPool(args: {
        configId: string;
        treasuryCapId: string;
        creator: string;
        coinType: string;
        quoteType: string;
    }): Transaction;
    claimTradingFee(args: {
        sender: string;
        coinType: string;
        quoteType: string;
        poolId?: string | null;
        ammId?: string | null;
    }): Transaction;
}
/** client.migration: graduate a completed curve into its AMM. */
declare class MigrationModule {
    private readonly sui;
    private readonly addr;
    constructor(sui: SuiClient, addr: MentaraAddresses);
    migrate(args: {
        poolId: string;
        configId: string;
        coinType: string;
        quoteType: string;
    }): Transaction;
}
export declare class MentaraClient {
    readonly sui: SuiClient;
    readonly addresses: MentaraAddresses;
    readonly state: StateModule;
    readonly pool: PoolModule;
    readonly partner: PartnerModule;
    readonly creator: CreatorModule;
    readonly migration: MigrationModule;
    constructor(sui: SuiClient, addresses: MentaraAddresses);
}
export {};
