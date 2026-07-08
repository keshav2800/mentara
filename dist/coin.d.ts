import { Transaction } from '@mysten/sui/transactions';
export interface CoinTemplate {
    bytecodeB64: string;
    dependencies: string[];
    /** Identifiers to rename: the OTW struct and the module name. */
    identifiers: {
        otw: string;
        module: string;
    };
    /** The template's compiled-in default constant values (to match on patch). */
    defaults: {
        symbol: string;
        name: string;
        description: string;
        iconUrl: string;
    };
}
export interface CoinMetadata {
    ticker: string;
    name: string;
    description: string;
    iconUrl: string;
}
/** Patch the template bytecode into a concrete coin. Returns base64 module. */
export declare function patchCoinBytecode(template: CoinTemplate, meta: CoinMetadata): string;
/**
 * Build a transaction that publishes the patched coin and makes the package
 * immutable (no upgrades, no rug). Sign with a funded publisher key. The
 * created TreasuryCap must then be passed to pool::create_pool, which locks it.
 */
export declare function buildPublishCoinTx(patchedModuleB64: string, dependencies: string[]): Transaction;
/** Derive the fully-qualified coin type from a published package id + ticker. */
export declare function coinTypeFor(packageId: string, ticker: string): string;
