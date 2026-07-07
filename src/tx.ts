// Transaction builders for the Mentara protocol. All are parameterized by a
// MentaraAddresses object, so they work against any deployment. Swap builders
// take a SuiClient only to fetch and merge the caller's coins; everything else
// is pure PTB construction.
import type { SuiClient } from '@mysten/sui/client';
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { SUI_CLOCK_OBJECT_ID } from '@mysten/sui/utils';
import type { CreateConfigParams, MentaraAddresses, Venue } from './types.js';
import { solveSingleSegmentCurve } from './math.js';

const mods = (a: MentaraAddresses) => ({
  pool: a.poolModule ?? 'pool',
  config: a.configModule ?? 'config',
  amm: a.ammModule ?? 'amm',
});

async function mergeAndSplit(
  tx: Transaction,
  client: SuiClient,
  sender: string,
  coinType: string,
  amount: bigint,
) {
  const coins = await client.getCoins({ owner: sender, coinType });
  if (coins.data.length === 0) throw new Error(`no ${coinType} coins for ${sender}`);
  const primary = tx.object(coins.data[0]!.coinObjectId);
  if (coins.data.length > 1) {
    tx.mergeCoins(primary, coins.data.slice(1).map((c) => tx.object(c.coinObjectId)));
  }
  return tx.splitCoins(primary, [tx.pure.u64(amount)])[0]!;
}

export interface BuildBuyArgs {
  addr: MentaraAddresses;
  client: SuiClient;
  sender: string;
  venue: Venue;
  poolOrAmmId: string;
  configId: string | null; // required for curve
  coinType: string;
  quoteType: string;
  amountRaw: bigint;
  minTokensRaw: bigint;
}

/** Buy tokens. Curve returns (tokens, refund) to sender; AMM returns tokens. */
export async function buildBuyTx(args: BuildBuyArgs): Promise<Transaction> {
  const m = mods(args.addr);
  const tx = new Transaction();
  tx.setSender(args.sender);
  const payment = await mergeAndSplit(tx, args.client, args.sender, args.quoteType, args.amountRaw);
  if (args.venue === 'curve') {
    if (!args.configId) throw new Error('configId required for curve buy');
    const [tokens, refund] = tx.moveCall({
      target: `${args.addr.packageId}::${m.pool}::buy`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [
        tx.object(args.poolOrAmmId),
        tx.object(args.configId),
        payment,
        tx.pure.u64(args.minTokensRaw),
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    });
    tx.transferObjects([tokens!, refund!], tx.pure.address(args.sender));
  } else {
    const [tokens] = tx.moveCall({
      target: `${args.addr.packageId}::${m.amm}::buy`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [
        tx.object(args.poolOrAmmId),
        payment,
        tx.pure.u64(args.minTokensRaw),
        tx.object(SUI_CLOCK_OBJECT_ID),
      ],
    });
    tx.transferObjects([tokens!], tx.pure.address(args.sender));
  }
  return tx;
}

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
export async function buildSellTx(args: BuildSellArgs): Promise<Transaction> {
  const m = mods(args.addr);
  if (args.venue === 'curve' && !args.configId) throw new Error('configId required for curve sell');
  const tx = new Transaction();
  tx.setSender(args.sender);
  const tokens = await mergeAndSplit(tx, args.client, args.sender, args.coinType, args.tokenRaw);
  const target =
    args.venue === 'curve'
      ? `${args.addr.packageId}::${m.pool}::sell`
      : `${args.addr.packageId}::${m.amm}::sell`;
  const callArgs =
    args.venue === 'curve'
      ? [
          tx.object(args.poolOrAmmId),
          tx.object(args.configId!),
          tokens,
          tx.pure.u64(args.minQuoteRaw),
          tx.object(SUI_CLOCK_OBJECT_ID),
        ]
      : [
          tx.object(args.poolOrAmmId),
          tokens,
          tx.pure.u64(args.minQuoteRaw),
          tx.object(SUI_CLOCK_OBJECT_ID),
        ];
  const [quote] = tx.moveCall({
    target,
    typeArguments: [args.coinType, args.quoteType],
    arguments: callArgs,
  });
  tx.transferObjects([quote!], tx.pure.address(args.sender));
  return tx;
}

/** Claim the creator's accrued fees from the curve pool and/or the AMM. */
export function buildClaimCreatorFeeTx(args: {
  addr: MentaraAddresses;
  sender: string;
  coinType: string;
  quoteType: string;
  poolId?: string | null;
  ammId?: string | null;
}): Transaction {
  const m = mods(args.addr);
  const tx = new Transaction();
  tx.setSender(args.sender);
  if (args.poolId) {
    tx.moveCall({
      target: `${args.addr.packageId}::${m.pool}::claim_creator_fee`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [tx.object(args.poolId)],
    });
  }
  if (args.ammId) {
    tx.moveCall({
      target: `${args.addr.packageId}::${m.amm}::claim_creator_fee`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [tx.object(args.ammId)],
    });
  }
  return tx;
}

/** Claim the partner (launchpad) accrued fees from the curve and/or the AMM. */
export function buildClaimPartnerFeeTx(args: {
  addr: MentaraAddresses;
  sender: string;
  coinType: string;
  quoteType: string;
  poolId?: string | null;
  configId?: string | null; // required if poolId is given (curve claim needs the config)
  ammId?: string | null;
}): Transaction {
  const m = mods(args.addr);
  const tx = new Transaction();
  tx.setSender(args.sender);
  if (args.poolId) {
    if (!args.configId) throw new Error('configId required to claim partner fee from the curve');
    tx.moveCall({
      target: `${args.addr.packageId}::${m.pool}::claim_partner_fee`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [tx.object(args.poolId), tx.object(args.configId)],
    });
  }
  if (args.ammId) {
    tx.moveCall({
      target: `${args.addr.packageId}::${m.amm}::claim_partner_fee`,
      typeArguments: [args.coinType, args.quoteType],
      arguments: [tx.object(args.ammId)],
    });
  }
  return tx;
}

/** Migrate a completed curve into its AMM (permissionless crank). */
export function buildMigrateTx(args: {
  addr: MentaraAddresses;
  poolId: string;
  configId: string;
  coinType: string;
  quoteType: string;
}): Transaction {
  const m = mods(args.addr);
  const tx = new Transaction();
  tx.moveCall({
    target: `${args.addr.packageId}::${m.pool}::migrate`,
    typeArguments: [args.coinType, args.quoteType],
    arguments: [tx.object(args.poolId), tx.object(args.configId), tx.object(SUI_CLOCK_OBJECT_ID)],
  });
  return tx;
}

/** Build create_config from human tokenomics (solves the curve for you). */
export function buildCreateConfigTx(addr: MentaraAddresses, p: CreateConfigParams): Transaction {
  const m = mods(addr);
  const scale = 10 ** p.tokenDecimals;
  const thresholdRaw = Math.round(p.thresholdQuote * scale);
  const { sqrtStart, sqrtEnd, liquidity } = solveSingleSegmentCurve({
    totalSupplyRaw: p.totalSupply * scale,
    thresholdRaw,
    priceRun: p.priceRun,
    migrationFeePct: p.migrationFeePct,
    bufferPct: 25,
  });
  const tx = new Transaction();
  tx.moveCall({
    target: `${addr.packageId}::${m.config}::create_config`,
    typeArguments: [p.quoteType],
    arguments: [
      tx.pure.address(p.partnerFeeClaimer),
      tx.pure.address(p.leftoverReceiver),
      tx.pure.u128(sqrtStart),
      tx.pure(bcs.vector(bcs.u128()).serialize([sqrtEnd])),
      tx.pure(bcs.vector(bcs.u128()).serialize([liquidity])),
      tx.pure.u8(p.feeMode),
      tx.pure.u64(p.cliffFeeNum),
      tx.pure.u64(p.periodMs),
      tx.pure.u64(p.feeReduction),
      tx.pure.u64(p.nPeriods),
      tx.pure.bool(p.firstSwapMinFee),
      tx.pure.u64(p.creatorLpFeePct),
      tx.pure.u64(p.migrationFeePct),
      tx.pure.u64(p.creatorMigrationFeePct),
      tx.pure.u64(p.ammFeeNum),
      tx.pure.u64(thresholdRaw),
      tx.pure.u64(p.poolCreationFee ?? 0),
      tx.pure.u64(p.activationDelayMs ?? 0),
      tx.pure.u8(p.tokenDecimals),
    ],
  });
  return tx;
}

/** Open a pool for a freshly published coin, attributing the creator. */
export function buildCreatePoolTx(args: {
  addr: MentaraAddresses;
  configId: string;
  treasuryCapId: string;
  creator: string;
  coinType: string;
  quoteType: string;
}): Transaction {
  const m = mods(args.addr);
  const tx = new Transaction();
  const [zeroFee] = tx.moveCall({ target: '0x2::coin::zero', typeArguments: [args.quoteType] });
  tx.moveCall({
    target: `${args.addr.packageId}::${m.pool}::create_pool`,
    typeArguments: [args.coinType, args.quoteType],
    arguments: [
      tx.object(args.addr.registryId),
      tx.object(args.configId),
      tx.object(args.treasuryCapId),
      tx.pure.address(args.creator),
      zeroFee!,
      tx.object(SUI_CLOCK_OBJECT_ID),
    ],
  });
  return tx;
}
