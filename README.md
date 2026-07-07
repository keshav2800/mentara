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

Instantiate one client with your Sui client and your deployment addresses, then use the namespaced modules: `client.state`, `client.pool`, `client.partner`, `client.creator`, `client.migration`.

```ts
import { SuiClient } from '@mysten/sui/client';
import { MentaraClient } from 'mentara';

const sui = new SuiClient({ url: 'https://fullnode.mainnet.sui.io:443' });

// Point the SDK at the Mentara instance you published.
const mentara = new MentaraClient(sui, {
  packageId: '0x...',
  registryId: '0x...',
});

// Read live state and quote a buy with exact curve math.
const state = await mentara.state.getPool(poolId);
const config = await mentara.state.getConfig(state.configId!);
const quote = mentara.pool.swapQuote({ state, config, amountInRaw: 10_000_000n, isBuy: true });

// Build the buy with a 5% slippage floor in one call.
const tx = await mentara.pool.buyWithSlippage({
  sender, poolOrAmmId: poolId, state, config,
  coinType, quoteType: config.quoteType, amountRaw: 10_000_000n,
});
// sign + execute tx with a wallet or a sponsor
```

Other namespaces:

```ts
// Launchpad operator: create a reusable config from human tokenomics.
const cfgTx = mentara.partner.createConfig({
  quoteType, partnerFeeClaimer, leftoverReceiver,
  totalSupply: 500_000, tokenDecimals: 6,
  thresholdQuote: 500, priceRun: 15,
  creatorLpFeePct: 50, migrationFeePct: 5, creatorMigrationFeePct: 50,
  ammFeeNum: 10_000_000, // 1%
  feeMode: 1, cliffFeeNum: 500_000_000, periodMs: 60_000, feeReduction: 49_000_000,
  nPeriods: 10, firstSwapMinFee: true,
});

// Creator: publish a coin, open its pool, claim earnings.
const publishTx = mentara.creator.publishCoin(template, { ticker: 'MOON', name: 'Moon', description: '', iconUrl });
const poolTx = mentara.creator.createPool({ configId, treasuryCapId, creator, coinType, quoteType });
const claimTx = mentara.creator.claimTradingFee({ sender: creator, coinType, quoteType, poolId, ammId });

// Anyone: graduate a completed curve into its AMM.
const migrateTx = mentara.migration.migrate({ poolId, configId, coinType, quoteType });
```

The standalone functions (`getPoolState`, `buildBuyTx`, `curveBaseOut`, `solveSingleSegmentCurve`, ...) are also exported if you prefer them over the client.

## Status

Testnet. The Move protocol and the curve, fee, graduation, and fee split logic are covered by Move unit tests and verified end to end on chain. Not yet audited.

## License

MIT, MS Mind Labs.
