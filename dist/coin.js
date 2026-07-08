// Programmatic coin creation: patch a precompiled coin-template module with a
// ticker/name/metadata, then publish it as a real Sui Coin. No Move compiler
// needed at runtime. The template bytecode + its default constants are passed
// in by the integrator (Mentara ships a reference template), keeping this
// deployment-agnostic.
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';
import { fromB64, toB64 } from '@mysten/sui/utils';
import { update_constants, update_identifiers } from '@mysten/move-bytecode-template';
/** Patch the template bytecode into a concrete coin. Returns base64 module. */
export function patchCoinBytecode(template, meta) {
    const lower = meta.ticker.toLowerCase();
    const upper = meta.ticker.toUpperCase();
    // WASM helpers return Uint8Array<ArrayBufferLike>; widen so reassignment
    // typechecks under TS 5.7 typed-array generics.
    let bytecode = fromB64(template.bytecodeB64);
    bytecode = update_identifiers(bytecode, {
        [template.identifiers.otw]: upper,
        [template.identifiers.module]: lower,
    });
    const patch = (from, to) => {
        bytecode = update_constants(bytecode, bcs.vector(bcs.u8()).serialize(new TextEncoder().encode(to)).toBytes(), bcs.vector(bcs.u8()).serialize(new TextEncoder().encode(from)).toBytes(), 'Vector(U8)');
    };
    patch(template.defaults.symbol, upper);
    patch(template.defaults.name, meta.name);
    patch(template.defaults.description, meta.description);
    patch(template.defaults.iconUrl, meta.iconUrl);
    return toB64(new Uint8Array(bytecode));
}
/**
 * Build a transaction that publishes the patched coin and makes the package
 * immutable (no upgrades, no rug). Sign with a funded publisher key. The
 * created TreasuryCap must then be passed to pool::create_pool, which locks it.
 */
export function buildPublishCoinTx(patchedModuleB64, dependencies) {
    const tx = new Transaction();
    const [upgradeCap] = tx.publish({ modules: [patchedModuleB64], dependencies });
    tx.moveCall({ target: '0x2::package::make_immutable', arguments: [upgradeCap] });
    return tx;
}
/** Derive the fully-qualified coin type from a published package id + ticker. */
export function coinTypeFor(packageId, ticker) {
    return `${packageId}::${ticker.toLowerCase()}::${ticker.toUpperCase()}`;
}
