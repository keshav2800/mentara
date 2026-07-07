#[test_only]
module hunchbook_launchpad::launchpad_tests {
    use hunchbook_launchpad::{
        amm::{Self, AmmPool},
        config::{Self, PoolConfig},
        math,
        pool::{Self, Registry, VirtualPool}
    };
    use std::unit_test::{assert_eq, destroy};
    use sui::{clock::{Self, Clock}, coin::{Self, Coin}, sui::SUI, test_scenario::{Self as ts, Scenario}};

    /// Test base coin — phantom type param for the launched token.
    public struct TESTBASE has drop {}

    const TREASURY: address = @0x77;
    const PARTNER: address = @0xFA;
    const LEFTOVER: address = @0x1E;
    const CREATOR: address = @0xC0FFEE;
    const ALICE: address = @0xA11CE;

    // Curve: single segment, price 1.0 → 4.0 (raw quote per raw base).
    const SQRT_START: u128 = 1 << 64;
    const SQRT_END: u128 = 2 << 64;
    const LIQ: u128 = 1 << 40;
    /// Segment quote capacity = LIQ · (SQRT_END − SQRT_START) / 2^64 = 2^40.
    const THRESHOLD: u64 = 1_000_000;

    const FEE_1PCT: u64 = 10_000_000; // over FEE_DENOM = 1e9
    const FEE_50PCT: u64 = 500_000_000;

    const MODE_FLAT: u8 = 0;
    const MODE_LINEAR: u8 = 1;
    const MODE_EXP: u8 = 2;

    // =====================================================================
    // Helpers
    // =====================================================================

    fun default_config(scenario: &mut Scenario): ID {
        config::create_config<SUI>(
            PARTNER,
            LEFTOVER,
            SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_FLAT,
            FEE_1PCT,
            0,
            0,
            0,
            false,
            50, // creator LP fee share → 20/40/40 waterfall
            5, // migration fee pct
            50, // creator migration fee share
            FEE_1PCT, // graduated AMM fee
            THRESHOLD,
            0, // pool creation fee
            0, // activation delay
            6,
            scenario.ctx(),
        )
    }

    fun setup_pool(scenario: &mut Scenario, clock: &Clock): (ID, ID) {
        let config_id = default_config(scenario);
        pool::init_for_testing(scenario.ctx());
        scenario.next_tx(TREASURY);
        let mut registry = scenario.take_shared<Registry>();
        let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
        let cap = coin::create_treasury_cap_for_testing<TESTBASE>(scenario.ctx());
        let pool_id = pool::create_pool<TESTBASE, SUI>(
            &mut registry,
            &cfg,
            cap,
            CREATOR,
            coin::zero<SUI>(scenario.ctx()),
            clock,
            scenario.ctx(),
        );
        ts::return_shared(registry);
        ts::return_shared(cfg);
        (config_id, pool_id)
    }

    fun buy(
        scenario: &mut Scenario,
        config_id: ID,
        pool_id: ID,
        clock: &Clock,
        amount: u64,
    ) {
        let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
        let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
        let payment = coin::mint_for_testing<SUI>(amount, scenario.ctx());
        let sender = scenario.ctx().sender();
        let (base, refund) = pool::buy(&mut p, &cfg, payment, 0, clock, scenario.ctx());
        // What the real PTB does: hand both outputs to the trader.
        transfer::public_transfer(base, sender);
        if (refund.value() > 0) {
            transfer::public_transfer(refund, sender);
        } else {
            refund.destroy_zero();
        };
        ts::return_shared(cfg);
        ts::return_shared(p);
    }

    // =====================================================================
    // Pure sqrt-price math
    // =====================================================================

    #[test]
    fun delta_quote_exact_powers_of_two() {
        // L·(√Pb − √Pa)/2^64 = 2^40 · 2^64 / 2^64 = 2^40
        assert_eq!(math::delta_quote_for_testing(LIQ, SQRT_START, SQRT_END, false), 1 << 40);
        assert_eq!(math::delta_quote_for_testing(LIQ, SQRT_START, SQRT_END, true), 1 << 40);
    }

    #[test]
    fun delta_base_exact_powers_of_two() {
        // L·(√Pb − √Pa)·2^64/(√Pa·√Pb) = 2^40·2^64·2^64/(2^64·2^65) = 2^39
        assert_eq!(math::delta_base_for_testing(LIQ, SQRT_START, SQRT_END, false), 1 << 39);
    }

    #[test]
    fun next_sqrt_from_quote_in_is_exact_step() {
        // step = q·2^64/L = 1000·2^24
        let s = math::next_sqrt_from_quote_in_for_testing(LIQ, SQRT_START, 1000);
        assert_eq!(s, SQRT_START + 1000 * (1 << 24));
    }

    #[test]
    fun buy_then_sell_round_trip_loses_only_dust() {
        // Walk up with q, walk back down with the base received: the quote
        // returned can never exceed what was paid, and dust loss is tiny.
        let q: u64 = 123_456;
        let s1 = math::next_sqrt_from_quote_in_for_testing(LIQ, SQRT_START, q);
        let base = math::delta_base_for_testing(LIQ, SQRT_START, s1, false);
        let s2 = math::next_sqrt_from_base_in_for_testing(LIQ, s1, base);
        assert!(s2 >= SQRT_START);
        let q_back = math::delta_quote_for_testing(LIQ, s2, s1, false);
        assert!(q_back <= q);
        assert!(q_back >= q - 3);
    }

    // =====================================================================
    // Config derivation & validation
    // =====================================================================

    #[test]
    fun config_derivation_is_self_consistent() {
        let mut scenario = ts::begin(TREASURY);
        let config_id = default_config(&mut scenario);
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            // Migration price sits inside the (only) segment.
            let sm = cfg.migration_sqrt_price();
            assert!(sm > SQRT_START && sm < SQRT_END);
            // A single buy of exactly the threshold reproduces the derived
            // migration point and base amount.
            let (base, s_after) =
                config::quote_to_base_for_testing(&cfg, SQRT_START, THRESHOLD);
            assert_eq!(s_after, sm);
            assert_eq!(base, cfg.swap_base_amount());
            // Supply = swap base + 25% buffer + migration base.
            assert_eq!(
                cfg.initial_base_supply(),
                cfg.swap_base_amount() + cfg.swap_base_amount() * 25 / 100
                    + cfg.migration_base_amount(),
            );
            ts::return_shared(cfg);
        };
        scenario.end();
    }

    #[test, expected_failure(abort_code = 4, location = hunchbook_launchpad::config)]
    fun config_rejects_unreachable_threshold() {
        let mut scenario = ts::begin(TREASURY);
        // Capacity is 2^40; ask for more.
        config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_FLAT, FEE_1PCT, 0, 0, 0, false,
            50, 5, 50, FEE_1PCT,
            (1 << 40) + 1, 0, 0, 6,
            scenario.ctx(),
        );
        abort 99
    }

    #[test, expected_failure(abort_code = 0, location = hunchbook_launchpad::config)]
    fun config_rejects_non_increasing_curve() {
        let mut scenario = ts::begin(TREASURY);
        config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END, SQRT_END],
            vector[LIQ, LIQ],
            MODE_FLAT, FEE_1PCT, 0, 0, 0, false,
            50, 5, 50, FEE_1PCT,
            THRESHOLD, 0, 0, 6,
            scenario.ctx(),
        );
        abort 99
    }

    #[test]
    fun multi_segment_walk_crosses_boundaries_both_ways() {
        let mut scenario = ts::begin(TREASURY);
        // Segment 1: 1<<64 → 2<<64 with L=2^40 (capacity 2^40 quote)
        // Segment 2: 2<<64 → 4<<64 with L=2^41 (capacity 2^42 quote)
        let config_id = config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[2 << 64, 4 << 64],
            vector[1 << 40, 1 << 41],
            MODE_FLAT, FEE_1PCT, 0, 0, 0, false,
            50, 5, 50, FEE_1PCT,
            1 << 41, // lands inside segment 2
            0, 0, 6,
            scenario.ctx(),
        );
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            // Exactly segment 1's capacity stops precisely at the boundary.
            let (b1, s1) = config::quote_to_base_for_testing(&cfg, SQRT_START, 1 << 40);
            assert_eq!(s1, 2 << 64);
            // More quote crosses into segment 2.
            let q2: u64 = (1 << 40) + (1 << 30);
            let (b2, s2) = config::quote_to_base_for_testing(&cfg, SQRT_START, q2);
            assert!(s2 > (2 << 64) && b2 > b1);
            // Selling everything back re-crosses the boundary and can never
            // return more quote than went in.
            let (q_back, s3) = config::base_to_quote_for_testing(&cfg, s2, b2);
            assert!(q_back <= q2);
            assert!(q_back >= q2 - 10);
            assert!(s3 >= SQRT_START);
            ts::return_shared(cfg);
        };
        scenario.end();
    }

    // =====================================================================
    // Fee scheduler
    // =====================================================================

    #[test]
    fun linear_scheduler_decays_stepwise_to_terminal() {
        let mut scenario = ts::begin(TREASURY);
        // 50% cliff, −4.9% per minute, 10 periods → terminal 1%.
        let config_id = config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_LINEAR, FEE_50PCT, 60_000, 49_000_000, 10, false,
            50, 5, 50, FEE_1PCT, THRESHOLD, 0, 0, 6,
            scenario.ctx(),
        );
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            assert_eq!(config::current_fee_num_for_testing(&cfg, 0, 0, false), FEE_50PCT);
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 59_999, false),
                FEE_50PCT,
            );
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 60_000, false),
                FEE_50PCT - 49_000_000,
            );
            // Past the last period the fee stays at the terminal 1%.
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 60_000 * 100, false),
                FEE_1PCT,
            );
            ts::return_shared(cfg);
        };
        scenario.end();
    }

    #[test]
    fun exponential_scheduler_decays_multiplicatively() {
        let mut scenario = ts::begin(TREASURY);
        // 50% cliff, ×0.7 per minute, 10 periods.
        let config_id = config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_EXP, FEE_50PCT, 60_000, 3_000, 10, false,
            50, 5, 50, FEE_1PCT, THRESHOLD, 0, 0, 6,
            scenario.ctx(),
        );
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            assert_eq!(config::current_fee_num_for_testing(&cfg, 0, 0, false), FEE_50PCT);
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 60_000, false),
                350_000_000,
            );
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 120_000, false),
                245_000_000,
            );
            ts::return_shared(cfg);
        };
        scenario.end();
    }

    #[test]
    fun first_swap_min_fee_overrides_scheduler() {
        let mut scenario = ts::begin(TREASURY);
        let config_id = config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_FLAT, FEE_50PCT, 0, 0, 0, true,
            50, 5, 50, FEE_1PCT, THRESHOLD, 0, 0, 6,
            scenario.ctx(),
        );
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            assert_eq!(
                config::current_fee_num_for_testing(&cfg, 0, 0, true),
                config::min_fee_num(),
            );
            assert_eq!(config::current_fee_num_for_testing(&cfg, 0, 0, false), FEE_50PCT);
            ts::return_shared(cfg);
        };
        scenario.end();
    }

    // =====================================================================
    // Pool lifecycle
    // =====================================================================

    #[test]
    fun create_pool_mints_exact_supply_and_registers() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);
        scenario.next_tx(TREASURY);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let registry = scenario.take_shared<Registry>();
            assert_eq!(pool::base_reserve_value(&p), cfg.initial_base_supply());
            assert_eq!(pool::quote_reserve_value(&p), 0);
            assert_eq!(pool::sqrt_price(&p), SQRT_START);
            assert_eq!(pool::creator(&p), CREATOR);
            assert_eq!(pool::pool_count(&registry), 1);
            ts::return_shared(cfg);
            ts::return_shared(p);
            ts::return_shared(registry);
        };
        destroy(clock);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 202, location = hunchbook_launchpad::pool)]
    fun create_pool_rejects_used_treasury_cap() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let config_id = default_config(&mut scenario);
        pool::init_for_testing(scenario.ctx());
        scenario.next_tx(TREASURY);
        {
            let mut registry = scenario.take_shared<Registry>();
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut cap = coin::create_treasury_cap_for_testing<TESTBASE>(scenario.ctx());
            // Pre-mint → supply is non-zero → must abort.
            let premint = coin::mint(&mut cap, 1, scenario.ctx());
            transfer::public_transfer(premint, TREASURY);
            pool::create_pool<TESTBASE, SUI>(
                &mut registry,
                &cfg,
                cap,
                CREATOR,
                coin::zero<SUI>(scenario.ctx()),
                &clock,
                scenario.ctx(),
            );
            abort 99
        }
    }

    #[test]
    fun buy_splits_fee_20_40_40_and_fills_reserve() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 100_000);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            // 1% of 100_000 = 1_000 fee → 200 protocol / 400 partner / 400 creator.
            let (fp, fpa, fc) = pool::fee_accruals(&p);
            assert_eq!(fp, 200);
            assert_eq!(fpa, 400);
            assert_eq!(fc, 400);
            assert_eq!(pool::quote_reserve_value(&p), 99_000);
            // Alice's tokens match the config walk for the net amount.
            let (expected_base, expected_sqrt) =
                config::quote_to_base_for_testing(&cfg, SQRT_START, 99_000);
            let alice_base = scenario.take_from_sender<Coin<TESTBASE>>();
            assert_eq!(alice_base.value(), expected_base);
            assert_eq!(pool::sqrt_price(&p), expected_sqrt);
            // Conservation: everything Alice paid is reserve + fee buckets.
            assert_eq!(100_000, pool::quote_reserve_value(&p) + fp + fpa + fc);
            destroy(alice_base);
            ts::return_shared(cfg);
            ts::return_shared(p);
        };
        destroy(clock);
        scenario.end();
    }

    #[test]
    fun sell_round_trip_loses_exactly_the_fees() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 100_000);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let alice_base = scenario.take_from_sender<Coin<TESTBASE>>();
            let quote_back =
                pool::sell(&mut p, &cfg, alice_base, 0, &clock, scenario.ctx());
            transfer::public_transfer(quote_back, ALICE);
            ts::return_shared(cfg);
            ts::return_shared(p);
        };

        scenario.next_tx(ALICE);
        {
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let quote_back = scenario.take_from_sender<Coin<SUI>>();
            // Paid 100_000. Buy fee 1_000. Sell fee ~1% of ~99_000 gross.
            // Net back must be under 98_020 and near it (dust only).
            assert!(quote_back.value() <= 98_020);
            assert!(quote_back.value() >= 97_990);
            // Conservation across the full round trip.
            let (fp, fpa, fc) = pool::fee_accruals(&p);
            assert_eq!(
                100_000,
                quote_back.value() + fp + fpa + fc + pool::quote_reserve_value(&p),
            );
            // Pool solvent: reserve never went negative (implicit) and all
            // base is back home.
            destroy(quote_back);
            ts::return_shared(p);
        };
        destroy(clock);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 208, location = hunchbook_launchpad::pool)]
    fun buy_respects_slippage_guard() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);
        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let payment = coin::mint_for_testing<SUI>(100_000, scenario.ctx());
            // Demand far more base than 99_000 net can buy.
            let (base, refund) =
                pool::buy(&mut p, &cfg, payment, 1_000_000_000, &clock, scenario.ctx());
            destroy(base);
            destroy(refund);
            abort 99
        }
    }

    #[test]
    fun graduation_partial_fills_refunds_and_halts() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);

        // Whale sends 2_000_000 gross — far past the 1_000_000 threshold.
        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 2_000_000);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            // Reserve landed EXACTLY on the threshold and the curve halted.
            assert_eq!(pool::quote_reserve_value(&p), THRESHOLD);
            assert!(pool::is_completed(&p));
            // Price landed exactly on the derived migration price, and the
            // whale received exactly the derived curve-sale amount.
            assert_eq!(pool::sqrt_price(&p), cfg.migration_sqrt_price());
            let alice_base = scenario.take_from_sender<Coin<TESTBASE>>();
            assert_eq!(alice_base.value(), cfg.swap_base_amount());
            // Refund: paid 2_000_000, used 1_000_000 + 1% fee on it.
            let refund = scenario.take_from_sender<Coin<SUI>>();
            assert_eq!(refund.value(), 2_000_000 - THRESHOLD - 10_000);
            destroy(alice_base);
            destroy(refund);
            ts::return_shared(cfg);
            ts::return_shared(p);
        };
        destroy(clock);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 205, location = hunchbook_launchpad::pool)]
    fun trading_halts_after_graduation() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);
        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 2_000_000);
        // Any further buy must abort E_COMPLETED.
        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 1_000);
        abort 99
    }

    #[test]
    fun claims_pay_fixed_recipients() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 100_000);

        // Anyone (Alice here) can crank the claims; funds go to the fixed
        // destinations regardless.
        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            pool::claim_protocol_fee(&mut p, scenario.ctx());
            pool::claim_partner_fee(&mut p, &cfg, scenario.ctx());
            pool::claim_creator_fee(&mut p, scenario.ctx());
            let (fp, fpa, fc) = pool::fee_accruals(&p);
            assert_eq!(fp, 0);
            assert_eq!(fpa, 0);
            assert_eq!(fc, 0);
            ts::return_shared(cfg);
            ts::return_shared(p);
        };

        scenario.next_tx(ALICE);
        {
            let protocol_coin = scenario.take_from_address<Coin<SUI>>(
                pool::protocol_fee_recipient_for_testing(),
            );
            let partner_coin = scenario.take_from_address<Coin<SUI>>(PARTNER);
            let creator_coin = scenario.take_from_address<Coin<SUI>>(CREATOR);
            assert_eq!(protocol_coin.value(), 200);
            assert_eq!(partner_coin.value(), 400);
            assert_eq!(creator_coin.value(), 400);
            destroy(protocol_coin);
            destroy(partner_coin);
            destroy(creator_coin);
        };
        destroy(clock);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 206, location = hunchbook_launchpad::pool)]
    fun activation_delay_blocks_early_trades() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let config_id = config::create_config<SUI>(
            PARTNER, LEFTOVER, SQRT_START,
            vector[SQRT_END],
            vector[LIQ],
            MODE_FLAT, FEE_1PCT, 0, 0, 0, false,
            50, 5, 50, FEE_1PCT, THRESHOLD, 0,
            10_000, // 10s activation delay
            6,
            scenario.ctx(),
        );
        pool::init_for_testing(scenario.ctx());
        scenario.next_tx(TREASURY);
        {
            let mut registry = scenario.take_shared<Registry>();
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let cap = coin::create_treasury_cap_for_testing<TESTBASE>(scenario.ctx());
            pool::create_pool<TESTBASE, SUI>(
                &mut registry,
                &cfg,
                cap,
                CREATOR,
                coin::zero<SUI>(scenario.ctx()),
                &clock,
                scenario.ctx(),
            );
            ts::return_shared(registry);
            ts::return_shared(cfg);
        };
        // Clock still at 0 < activation 10_000 → must abort E_NOT_ACTIVE.
        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared<VirtualPool<TESTBASE, SUI>>();
            let payment = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
            let (base, refund) = pool::buy(&mut p, &cfg, payment, 0, &clock, scenario.ctx());
            destroy(base);
            destroy(refund);
            abort 99
        }
    }

    // =====================================================================
    // Migration → graduated AMM
    // =====================================================================

    /// Drive a fresh pool to completion, migrate it, and return the ids.
    fun setup_graduated(scenario: &mut Scenario, clock: &Clock): (ID, ID, ID) {
        let (config_id, pool_id) = setup_pool(scenario, clock);
        scenario.next_tx(ALICE);
        buy(scenario, config_id, pool_id, clock, 2_000_000);
        scenario.next_tx(ALICE);
        let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
        let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
        let amm_id = pool::migrate(&mut p, &cfg, clock, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(p);
        (config_id, pool_id, amm_id)
    }

    #[test]
    fun migrate_splits_every_unit_correctly() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id, amm_id) = setup_graduated(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let g = scenario.take_shared_by_id<AmmPool<TESTBASE, SUI>>(amm_id);
            assert!(pool::is_migrated(&p));

            // Quote side: threshold 1_000_000 → 5% migration fee (50_000,
            // half to creator) → 20 bps protocol liq fee off the remaining
            // 950_000 (1_900) → 948_100 into the AMM.
            let (amm_base, amm_quote) = amm::reserves(&g);
            assert_eq!(amm_quote, 948_100);
            // Base side: min(migration_base_amount, reserve) minus 20 bps.
            let base_gross = cfg.migration_base_amount();
            assert_eq!(amm_base, base_gross - base_gross * 20 / 10_000);
            // Old pool is fully drained: quote all distributed, base either
            // in the AMM, at the protocol, or sent to the leftover receiver.
            assert_eq!(pool::quote_reserve_value(&p), 0);
            assert_eq!(pool::base_reserve_value(&p), 0);
            // Migration fee sits in the curve pool's claim buckets on top of
            // the whale's trading fee (10_000 → partner 4_000, creator 4_000).
            let (_, fpa, fc) = pool::fee_accruals(&p);
            assert_eq!(fpa, 4_000 + 25_000);
            assert_eq!(fc, 4_000 + 25_000);
            ts::return_shared(cfg);
            ts::return_shared(p);
            ts::return_shared(g);
        };

        scenario.next_tx(ALICE);
        {
            // Protocol wallet got both liq-fee coins; leftover receiver got
            // the unused buffer tokens.
            let proto_quote = scenario.take_from_address<Coin<SUI>>(
                pool::protocol_fee_recipient_for_testing(),
            );
            assert_eq!(proto_quote.value(), 1_900);
            let proto_base = scenario.take_from_address<Coin<TESTBASE>>(
                pool::protocol_fee_recipient_for_testing(),
            );
            let leftover = scenario.take_from_address<Coin<TESTBASE>>(LEFTOVER);
            // Conservation: everything minted is either sold (whale), in the
            // AMM, at the protocol, or leftover.
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let g = scenario.take_shared_by_id<AmmPool<TESTBASE, SUI>>(amm_id);
            let (amm_base, _) = amm::reserves(&g);
            assert_eq!(
                cfg.initial_base_supply(),
                cfg.swap_base_amount() + amm_base + proto_base.value() + leftover.value(),
            );
            destroy(proto_quote);
            destroy(proto_base);
            destroy(leftover);
            ts::return_shared(cfg);
            ts::return_shared(g);
        };
        destroy(clock);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 210, location = hunchbook_launchpad::pool)]
    fun migrate_requires_completion() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);
        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            pool::migrate(&mut p, &cfg, &clock, scenario.ctx());
            abort 99
        }
    }

    #[test, expected_failure(abort_code = 211, location = hunchbook_launchpad::pool)]
    fun migrate_runs_only_once() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id, _amm_id) = setup_graduated(&mut scenario, &clock);
        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            pool::migrate(&mut p, &cfg, &clock, scenario.ctx());
            abort 99
        }
    }

    #[test]
    fun amm_trades_at_migration_price_with_waterfall_fees() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (_config_id, _pool_id, amm_id) = setup_graduated(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        {
            let mut g = scenario.take_shared_by_id<AmmPool<TESTBASE, SUI>>(amm_id);
            let (base_r, quote_r) = amm::reserves(&g);
            // Buy 100_000 quote: 1% fee → 1_000; x·y=k on the net 99_000.
            let payment = coin::mint_for_testing<SUI>(100_000, scenario.ctx());
            let out = amm::buy(&mut g, payment, 0, &clock, scenario.ctx());
            let expected =
                ((base_r as u128) * 99_000u128 / ((quote_r as u128) + 99_000u128)) as u64;
            assert_eq!(out.value(), expected);
            // Fee waterfall: 20/40/40 of 1_000.
            let (fp, fpa, fc) = amm::fee_accruals(&g);
            assert_eq!(fp, 200);
            assert_eq!(fpa, 400);
            assert_eq!(fc, 400);
            // Sell everything straight back; conservation must hold exactly.
            let quote_back = amm::sell(&mut g, out, 0, &clock, scenario.ctx());
            let (fp2, fpa2, fc2) = amm::fee_accruals(&g);
            let (_, quote_r_after) = amm::reserves(&g);
            assert_eq!(
                100_000 + quote_r,
                quote_back.value() + fp2 + fpa2 + fc2 + quote_r_after,
            );
            destroy(quote_back);
            ts::return_shared(g);
        };
        destroy(clock);
        scenario.end();
    }

    #[test]
    fun amm_claims_pay_fixed_recipients() {
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (_config_id, _pool_id, amm_id) = setup_graduated(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        {
            let mut g = scenario.take_shared_by_id<AmmPool<TESTBASE, SUI>>(amm_id);
            let payment = coin::mint_for_testing<SUI>(100_000, scenario.ctx());
            let out = amm::buy(&mut g, payment, 0, &clock, scenario.ctx());
            transfer::public_transfer(out, ALICE);
            amm::claim_protocol_fee(&mut g, scenario.ctx());
            amm::claim_partner_fee(&mut g, scenario.ctx());
            amm::claim_creator_fee(&mut g, scenario.ctx());
            ts::return_shared(g);
        };
        scenario.next_tx(ALICE);
        {
            let proto = scenario.take_from_address<Coin<SUI>>(
                pool::protocol_fee_recipient_for_testing(),
            );
            let partner = scenario.take_from_address<Coin<SUI>>(PARTNER);
            let creator = scenario.take_from_address<Coin<SUI>>(CREATOR);
            assert_eq!(proto.value(), 200);
            assert_eq!(partner.value(), 400);
            assert_eq!(creator.value(), 400);
            destroy(proto);
            destroy(partner);
            destroy(creator);
        };
        destroy(clock);
        scenario.end();
    }

    #[test]
    fun sell_back_buffer_survives_full_churn() {
        // Buy to just under the threshold, sell everything, buy again to the
        // threshold: the pool's base vault must never run short.
        let mut scenario = ts::begin(TREASURY);
        let clock = clock::create_for_testing(scenario.ctx());
        let (config_id, pool_id) = setup_pool(&mut scenario, &clock);

        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 900_000);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let mut p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            let alice_base = scenario.take_from_sender<Coin<TESTBASE>>();
            let quote_back =
                pool::sell(&mut p, &cfg, alice_base, 0, &clock, scenario.ctx());
            transfer::public_transfer(quote_back, ALICE);
            // Price returned to (or a dust above) the start.
            assert!(pool::sqrt_price(&p) >= SQRT_START);
            ts::return_shared(cfg);
            ts::return_shared(p);
        };

        // Grind through to graduation after the churn.
        scenario.next_tx(ALICE);
        buy(&mut scenario, config_id, pool_id, &clock, 2_000_000);

        scenario.next_tx(ALICE);
        {
            let cfg = scenario.take_shared_by_id<PoolConfig>(config_id);
            let p = scenario.take_shared_by_id<VirtualPool<TESTBASE, SUI>>(pool_id);
            assert!(pool::is_completed(&p));
            assert_eq!(pool::quote_reserve_value(&p), THRESHOLD);
            // Base vault still covers the migration reserve — the buffer did
            // its job through a full sell-and-rebuy cycle.
            assert!(pool::base_reserve_value(&p) >= cfg.migration_base_amount());
            ts::return_shared(cfg);
            ts::return_shared(p);
        };
        destroy(clock);
        scenario.end();
    }
}
