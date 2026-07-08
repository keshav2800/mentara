import type { SuiClient } from '@mysten/sui/client';
import type { LaunchConfig, PoolState } from './types.js';
/** Read a bonding-curve VirtualPool's live state. */
export declare function getPoolState(client: SuiClient, poolId: string): Promise<PoolState>;
/** Read a graduated AmmPool's reserves and fee state. */
export declare function getAmmState(client: SuiClient, ammId: string): Promise<PoolState>;
/** Read an immutable launch config: quote, threshold, scheduler, curve. */
export declare function getLaunchConfig(client: SuiClient, configId: string): Promise<LaunchConfig>;
