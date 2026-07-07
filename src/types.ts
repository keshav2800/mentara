import type { CurveSeg, FeeSchedule } from './math.js';

/**
 * Deployment addresses for a Mentara instance. The SDK is deployment-agnostic:
 * you pass the package and registry you published, so anyone can run their own
 * Mentara without touching the code.
 */
export interface MentaraAddresses {
  packageId: string;
  registryId: string;
  /** Module names, in case a fork renames them. Defaults match the reference package. */
  poolModule?: string; // default 'pool'
  configModule?: string; // default 'config'
  ammModule?: string; // default 'amm'
}

export type Venue = 'curve' | 'amm';

/** Live on-chain state of a pool (curve VirtualPool or graduated AmmPool). */
export interface PoolState {
  venue: Venue;
  configId: string | null; // curve only
  sqrtPrice: bigint; // curve only
  baseReserve: bigint;
  quoteReserve: bigint;
  activationMs: number;
  swapCount: number;
  isCompleted: boolean;
  /** AMM trading fee numerator; for curves resolve via the config scheduler. */
  feeNum: number;
  /** Creator's unclaimed earnings in this pool (raw quote units). */
  creatorFeesRaw: bigint;
  /** Partner (launchpad) unclaimed earnings (raw quote units). */
  partnerFeesRaw: bigint;
}

/** An immutable launch config (the reusable partner template). */
export interface LaunchConfig extends FeeSchedule {
  quoteType: string;
  thresholdRaw: bigint;
  ammFeeNum: number;
  segments: CurveSeg[];
}

/** Human tokenomics for creating a config via solveSingleSegmentCurve. */
export interface CreateConfigParams {
  quoteType: string;
  partnerFeeClaimer: string;
  leftoverReceiver: string;
  totalSupply: number; // whole tokens
  tokenDecimals: number; // 6..9
  thresholdQuote: number; // graduation, in whole quote units
  priceRun: number; // graduation price ÷ launch price
  creatorLpFeePct: number; // creator's share of the LP fee
  migrationFeePct: number;
  creatorMigrationFeePct: number;
  ammFeeNum: number; // graduated pool fee, over FEE_DENOM
  // fee scheduler
  feeMode: number;
  cliffFeeNum: number;
  periodMs: number;
  feeReduction: number;
  nPeriods: number;
  firstSwapMinFee: boolean;
  poolCreationFee?: number;
  activationDelayMs?: number;
}
