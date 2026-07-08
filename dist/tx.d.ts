import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import type { CreateConfigParams, MentaraAddresses, Venue } from './types.js';
export interface BuildBuyArgs {
    addr: MentaraAddresses;
    client: SuiClient;
    sender: string;
    venue: Venue;
    poolOrAmmId: string;
    configId: string | null;
    coinType: string;
    quoteType: string;
    amountRaw: bigint;
    minTokensRaw: bigint;
}
/** Buy tokens. Curve returns (tokens, refund) to sender; AMM returns tokens. */
export declare function buildBuyTx(args: BuildBuyArgs): Promise<Transaction>;
export interface BuildSellArgs {
    addr: MentaraAddresses;
    client: SuiClient;
    sender: string;
    venue: Venue;
    poolOrAmmId: string;
    configId: string | null;
    coinType: string;
    quoteType: string;
    tokenRaw: bigint;
    minQuoteRaw: bigint;
}
/** Sell tokens for quote to sender. */
export declare function buildSellTx(args: BuildSellArgs): Promise<Transaction>;
/** Claim the creator's accrued fees from the curve pool and/or the AMM. */
export declare function buildClaimCreatorFeeTx(args: {
    addr: MentaraAddresses;
    sender: string;
    coinType: string;
    quoteType: string;
    poolId?: string | null;
    ammId?: string | null;
}): Transaction;
/** Claim the partner (launchpad) accrued fees from the curve and/or the AMM. */
export declare function buildClaimPartnerFeeTx(args: {
    addr: MentaraAddresses;
    sender: string;
    coinType: string;
    quoteType: string;
    poolId?: string | null;
    configId?: string | null;
    ammId?: string | null;
}): Transaction;
/** Migrate a completed curve into its AMM (permissionless crank). */
export declare function buildMigrateTx(args: {
    addr: MentaraAddresses;
    poolId: string;
    configId: string;
    coinType: string;
    quoteType: string;
}): Transaction;
/** Build create_config from human tokenomics (solves the curve for you). */
export declare function buildCreateConfigTx(addr: MentaraAddresses, p: CreateConfigParams): Transaction;
/** Open a pool for a freshly published coin, attributing the creator. */
export declare function buildCreatePoolTx(args: {
    addr: MentaraAddresses;
    configId: string;
    treasuryCapId: string;
    creator: string;
    coinType: string;
    quoteType: string;
}): Transaction;
