# Mentara

A dynamic bonding curve launch protocol and SDK for [Sui](https://sui.io). Mentara is the engine that powers token launchpads: launch a real coin, trade it on a bonding curve, graduate it to an automated market maker, and split the fees between the creator and the launchpad. Modeled on Meteora's Dynamic Bonding Curve, built for Sui.

Mentara is built by MS Mind Labs and powers [Hunchbook](https://hunchbook.xyz), the first launchpad built on it.

## What it does

- One click token launch: mint a real Sui `Coin` with fixed supply, no Move compiler needed at runtime.
- Bonding curve trading: buyers price in along a configurable curve, no seeded liquidity required.
- Anti sniper fee scheduler: fees start high and decay, with a first buy exemption for the creator.
- Graduation: when the curve fills, liquidity migrates to a locked constant product AMM at the exact final price.
- Fee splitting: every trade's fee is split between protocol, launchpad, and creator, each claiming independently, forever.

## Architecture

- `move/` the on chain protocol (Move packages): `config`, `pool`, `amm`, `math`, plus a `coin_template` used for programmatic coin creation.
- `src/` the TypeScript SDK, framework agnostic and deployment agnostic. You pass in the addresses of the Mentara instance you published, so anyone can run their own.

### SDK modules

- `math` pure pricing: curve quoting, the fee scheduler, AMM quoting, and a curve solver that turns human tokenomics (supply, threshold, price run) into on chain curve parameters.
- `read` read live pool and config state from chain.
- `tx` build every transaction: buy, sell, claim fees, migrate, create config, create pool.
- `coin` patch the coin template with a ticker and metadata and publish it as a real immutable coin.

## Install

```
pnpm add mentara @mysten/sui
```

## Quick start

```ts
import { SuiClient } from '@mysten/sui/client';
import {
  getPoolState, getLaunchConfig, currentFeeNum, curveBaseOut,
  ceilFeeRaw, buildBuyTx, type MentaraAddresses,
} from 'mentara';

const client = new SuiClient({ url: 'https://fullnode.mainnet.sui.io:443' });

// Your published Mentara deployment.
const addr: MentaraAddresses = {
  packageId: '0x...',
  registryId: '0x...',
};

// Quote a buy with exact curve math (so slippage floors are correct).
const state = await getPoolState(client, poolId);
const cfg = await getLaunchConfig(client, state.configId!);
const feeNum = currentFeeNum(cfg, state.activationMs, Date.now(), state.swapCount === 0);
const amountRaw = 10_000_000n; // 10 units at 6 decimals
const net = amountRaw - ceilFeeRaw(amountRaw, feeNum);
const capacity = Number(cfg.thresholdRaw - state.quoteReserve);
const tokensOut = curveBaseOut(cfg.segments, state.sqrtPrice, Number(net), capacity);

// Build the buy transaction (sign and execute with your wallet or a sponsor).
const tx = await buildBuyTx({
  addr, client, sender, venue: 'curve',
  poolOrAmmId: poolId, configId: state.configId, coinType, quoteType: cfg.quoteType,
  amountRaw, minTokensRaw: BigInt(Math.floor(tokensOut * 0.95)),
});
```

## Status

Testnet. The Move protocol and the curve, fee, graduation, and fee split logic are covered by Move unit tests and verified end to end on chain. Not yet audited.

## License

MIT, MS Mind Labs.
