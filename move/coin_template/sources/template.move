// The one-click-launch coin blueprint. This package is NEVER published as-is:
// its compiled bytecode is committed to the repo (see
// scripts/src/gen-coin-template.ts) and, at launch time, the server patches
// it with @mysten/move-bytecode-template — renaming the module + OTW to the
// user's ticker and swapping every constant below — then publishes the
// patched package. One publish per launched coin.
//
// Rules this file must follow for the patching to work:
//   - every user-visible value is a named `const` (they live in the module's
//     constant pool, which is what update_constants edits)
//   - every default value is UNIQUE within the file (the compiler dedupes
//     identical constants; a shared entry would get patched twice)
//   - module name `template` and OTW `TEMPLATE` are renamed by
//     update_identifiers; the OTW must stay the uppercased module name
// `coin::create_currency` is deprecated in favour of the new coin_registry
// standard, but it is permanent, universally understood by wallets/explorers/
// DEXes, and the bytecode-patching pipeline is proven against it. Revisit
// coin_registry::new_currency_with_otw as a future template upgrade.
#[allow(deprecated_usage)]
module coin_template::template;

use sui::coin;
use sui::url;

const DECIMALS: u8 = 6;
const SYMBOL: vector<u8> = b"TMPL";
const NAME: vector<u8> = b"Template Coin Name";
const DESCRIPTION: vector<u8> = b"Template Coin Description";
const ICON_URL: vector<u8> = b"https://template.invalid/icon.png";

public struct TEMPLATE has drop {}

fun init(witness: TEMPLATE, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        DECIMALS,
        SYMBOL,
        NAME,
        DESCRIPTION,
        option::some(url::new_unsafe_from_bytes(ICON_URL)),
        ctx,
    );
    // Metadata is frozen — name/symbol/icon are permanent, like the supply.
    transfer::public_freeze_object(metadata);
    // The cap goes to the publisher (our treasury), which immediately locks
    // it inside the launchpad pool via create_pool. No mint path survives.
    transfer::public_transfer(treasury_cap, ctx.sender());
}
