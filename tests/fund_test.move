module obj_cap::fund_tests;

use obj_cap::fund::{
    Self,
    WithdrawCap,
    TradeCap,
    Order,
    Fund,
    Exchange,
    create_test_order_pair,
    create_trader,
    create_order,
    get_existed_balance,
    get_fund_total_shares,
    get_withdraw_cap_amount,
    get_withdraw_cap_fund_id,
    add_asset_type_for_testing,
    Trader,
    Pair,
    exchange_contains_sell_order,
    create
};
use std::type_name::{get, TypeName};
use sui::balance::destroy_for_testing;
use sui::coin::{mint_for_testing, Coin, value};
use sui::object::id;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, take_shared};
use sui::test_utils::assert_eq;
use sui::vec_map::{Self, VecMap};

const ADMIN: address = @0xCAFE; // Use a different address for admin/creator if needed
const ALICE: address = @0x114;
const BOB: address = @0x514;
const TRADER_ADDR: address = @0x724; // Address for the trader

const RESERVE: u64 = 10;

// --- Mock Assets ---
public struct MOCK_A has drop {}
public struct MOCK_B has drop {}

// --- Helper Functions ---

// Helper to get the WithdrawCap from the sender's inventory
// Assumes only one WithdrawCap is expected
fun take_withdraw_cap(ts: &ts::Scenario): WithdrawCap {
    ts.take_from_sender<WithdrawCap>()
}

fun take_fund(ts: &ts::Scenario): Fund {
    ts.take_shared<Fund>()
}

// Helper to get TradeCap
fun take_trade_cap(ts: &ts::Scenario): TradeCap {
    ts.take_shared<TradeCap>()
}

// Helper to get Order
fun take_order(ts: &ts::Scenario): Order {
    ts.take_shared<Order>() // Orders are shared
}

// Helper to get Order
fun take_trader(ts: &ts::Scenario): Trader {
    ts.take_from_sender<Trader>() // trader is owned
}

// Helper to get Exchange
fun take_exchange(ts: &ts::Scenario): Exchange {
    ts.take_shared<Exchange>() // Exchanges are shared
}

// --- Test Setup Helpers ---

// Creates a Fund object using the ADMIN address.
fun setup_fund(ts: &mut ts::Scenario): Fund {
    ts.next_tx(ADMIN); // Ensure ADMIN is the sender for creation
    create(RESERVE, ts.ctx());
    ts.next_tx(ADMIN); // Switch back to ADMIN to take the fund
    take_fund(ts)
}

// Deposits a specified amount of SUI for a given user into the fund.
// Returns the WithdrawCap generated.
fun deposit_sui_for_user(
    ts: &mut ts::Scenario,
    fund: &mut Fund,
    user: address,
    amount: u64,
): WithdrawCap {
    // Mint SUI for the user
    ts.next_tx(ADMIN); // Admin mints
    let coin: Coin<SUI> = mint_for_testing(amount, ts.ctx());
    transfer::public_transfer(coin, user);

    // User Deposits
    ts.next_tx(user);
    let coin_to_deposit = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&coin_to_deposit), amount);
    fund::deposit(fund, coin_to_deposit, ts.ctx());

    // User takes the WithdrawCap
    ts.next_tx(user);
    take_withdraw_cap(ts)
}

// Creates a Trader object for the TRADER_ADDR.
fun setup_trader(ts: &mut ts::Scenario): Trader {
    ts.next_tx(TRADER_ADDR); // Switch to trader's address
    create_trader(ts.ctx());
    ts.next_tx(TRADER_ADDR); // Switch back to take the trader object
    take_trader(ts)
}

// Grants trade capability from the fund (owned by ADMIN) to the trader.
// Returns the TradeCap.
fun grant_trade_cap(ts: &mut ts::Scenario, fund: &Fund, trader: &Trader): TradeCap {
    ts.next_tx(ADMIN); // Admin grants
    fund::grant_trade(fund, trader, ts.ctx());
    ts.next_tx(TRADER_ADDR); // Trader takes the cap
    take_trade_cap(ts)
}

// Creates an order using the provided details.
// Assumes the current sender is the TRADER_ADDR.
fun create_test_order(
    ts: &mut ts::Scenario,
    fund: &Fund,
    trader: &Trader,
    trade_cap: TradeCap,
    buy_orders: VecMap<TypeName, Pair>,
    sell_orders: VecMap<TypeName, Pair>,
): Order {
    create_order(fund, trader, trade_cap, buy_orders, sell_orders, ts.ctx());
    ts.next_tx(TRADER_ADDR); // Switch to Admin (or any other user) to take the shared order
    take_order(ts)
}

// Verifies and prepares an exchange for a given order.
// Assumes the current sender is ADMIN.
fun prepare_exchange(ts: &mut ts::Scenario, fund: &mut Fund, order: Order): Exchange {
    fund::verify_and_prepare_exchange(fund, order, ts.ctx());
    ts.next_tx(TRADER_ADDR); // Switch to Admin (or any other user) to take the shared exchange
    take_exchange(ts)
}

#[test]
fun test_deposit_and_withdraw() {
    let mut ts = ts::begin(ADMIN);
    let mut fund = setup_fund(&mut ts);

    let deposit_amount = 1_000_000;
    let cap = deposit_sui_for_user(&mut ts, &mut fund, BOB, deposit_amount);

    // Check Fund State after deposit
    assert_eq(get_existed_balance<SUI>(&fund), deposit_amount);
    assert_eq(get_fund_total_shares(&fund), deposit_amount);
    assert_eq(get_withdraw_cap_amount(&cap), deposit_amount);
    assert_eq(get_withdraw_cap_fund_id(&cap), object::id(&fund));

    // Bob Withdraws
    ts.next_tx(BOB);
    fund::withdraw(&mut fund, cap, BOB, ts.ctx());

    // Check Final Fund State
    assert_eq(get_existed_balance<SUI>(&fund), 0);
    assert_eq(get_fund_total_shares(&fund), 0);

    ts::return_shared(fund);

    // Check Bob received the coin
    ts.next_tx(BOB);
    let withdrawn_coin = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_coin), deposit_amount);
    ts.return_to_sender(withdrawn_coin);

    ts.end();
}

#[test]
/// Tests multiple deposits from different users and subsequent withdrawals.
fun test_multiple_deposits_and_withdrawals() {
    let mut ts = ts::begin(ADMIN);
    let mut fund = setup_fund(&mut ts);

    let deposit_alice = 1_000_000;
    let deposit_bob = 2_000_000;
    let total_deposit = deposit_alice + deposit_bob;

    let cap_alice = deposit_sui_for_user(&mut ts, &mut fund, ALICE, deposit_alice);
    assert_eq(get_existed_balance<SUI>(&fund), deposit_alice);
    assert_eq(get_fund_total_shares(&fund), deposit_alice);

    let cap_bob = deposit_sui_for_user(&mut ts, &mut fund, BOB, deposit_bob);
    assert_eq(get_existed_balance<SUI>(&fund), total_deposit);
    assert_eq(get_fund_total_shares(&fund), total_deposit);

    // Alice Withdraws
    ts.next_tx(ALICE);
    let expected_alice_withdrawal =
        (get_existed_balance<SUI>(&fund) * get_withdraw_cap_amount(&cap_alice)) / get_fund_total_shares(&fund);
    fund::withdraw(&mut fund, cap_alice, ALICE, ts.ctx());

    // Check state after Alice's withdrawal
    assert_eq(get_existed_balance<SUI>(&fund), total_deposit - expected_alice_withdrawal);
    assert_eq(get_fund_total_shares(&fund), deposit_bob);

    // Bob Withdraws
    ts.next_tx(BOB);
    let expected_bob_withdrawal =
        (get_existed_balance<SUI>(&fund) * get_withdraw_cap_amount(&cap_bob)) / get_fund_total_shares(&fund);
    fund::withdraw(&mut fund, cap_bob, BOB, ts.ctx());

    // Check final state
    assert_eq(get_existed_balance<SUI>(&fund), 0);
    assert_eq(get_fund_total_shares(&fund), 0);

    ts::return_shared(fund);

    // Verify received amounts
    ts.next_tx(ALICE);
    let withdrawn_alice = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_alice), expected_alice_withdrawal);
    destroy_for_testing(withdrawn_alice.into_balance());

    ts.next_tx(BOB);
    let withdrawn_bob = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_bob), expected_bob_withdrawal);
    destroy_for_testing(withdrawn_bob.into_balance());

    ts.end();
}

// --- Negative Test Cases ---

#[test]
#[expected_failure(abort_code = obj_cap::fund::FundMismatch)]
fun test_withdraw_with_wrong_fund_cap() {
    let mut ts = ts::begin(ADMIN);

    // Create Fund A (Alice is admin for simplicity here)
    ts.next_tx(ALICE);
    create(RESERVE, ts.ctx());
    ts.next_tx(ALICE);
    let mut fund_a = take_fund(&ts);

    // Create Fund B (Bob is admin)
    ts.next_tx(BOB);
    create(RESERVE, ts.ctx());
    ts.next_tx(BOB);
    let mut fund_b = take_fund(&ts);

    // Alice deposits into Fund A to get a cap
    let deposit_amount = 100;
    let cap_a = deposit_sui_for_user(&mut ts, &mut fund_a, ALICE, deposit_amount);
    assert_eq(get_withdraw_cap_fund_id(&cap_a), id(&fund_a));

    // Alice tries to withdraw from Fund B using Cap A
    ts.next_tx(ALICE);
    fund::withdraw(&mut fund_b, cap_a, ALICE, ts.ctx()); // This should fail

    // Cleanup (won't be reached on abort)
    ts::return_shared(fund_b);
    ts::return_shared(fund_a);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InsufficientDeposit)]
fun test_deposit_less_than_reserve() {
    let mut ts = ts::begin(ADMIN);
    let mut fund = setup_fund(&mut ts);

    let deposit_amount = RESERVE - 1;
    // deposit_sui_for_user handles mint, transfer, deposit attempt
    let cap = deposit_sui_for_user(&mut ts, &mut fund, BOB, deposit_amount); // Should fail here

    ts::return_shared(fund);
    ts.return_to_sender(cap);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InsufficientDeposit)]
fun test_deposit_equal_to_reserve() {
    let mut ts = ts::begin(ADMIN);
    let mut fund = setup_fund(&mut ts);

    let deposit_amount = RESERVE;
    // deposit_sui_for_user handles mint, transfer, deposit attempt
    let cap = deposit_sui_for_user(&mut ts, &mut fund, BOB, deposit_amount); // Should fail here

    ts::return_shared(fund);
    ts.return_to_sender(cap);
    ts.end();
}

#[test]
fun test_cap_consumption() {
    let mut ts = ts::begin(ADMIN);
    let mut fund = setup_fund(&mut ts);

    let deposit_amount = 500;
    let cap = deposit_sui_for_user(&mut ts, &mut fund, BOB, deposit_amount);

    // Bob Withdraws
    ts.next_tx(BOB);
    fund::withdraw(&mut fund, cap, BOB, ts.ctx());
    ts::return_shared(fund);

    // Bob should now have the withdrawn Coin, but NOT the WithdrawCap
    ts.next_tx(BOB);
    let withdrawn_coin = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_coin), deposit_amount);

    // Implicit check: if cap wasn't consumed, take_from_sender<WithdrawCap> would be possible.
    // The test framework helps by ensuring only expected objects are taken.

    destroy_for_testing(withdrawn_coin.into_balance());
    ts.end();
}

// --- Trading Lifecycle Tests ---

// Enhanced setup for trading tests
fun setup_trading_environment(ts: &mut ts::Scenario): (Fund, Trader) {
    let mut fund = setup_fund(ts);

    // Add mock assets
    ts.next_tx(ADMIN);
    add_asset_type_for_testing<MOCK_A>(&mut fund);
    add_asset_type_for_testing<MOCK_B>(&mut fund);

    // Deposit initial SUI and MOCK_A
    let initial_sui = 1_000_000;
    let initial_mock_a = 50;

    // Deposit SUI (ignore the withdraw cap for these tests)
    let cap = deposit_sui_for_user(ts, &mut fund, ADMIN, initial_sui);
    ts.return_to_sender(cap);

    // Grant MOCK_A directly for testing
    ts.next_tx(ADMIN);
    let mock_a_coin = mint_for_testing(initial_mock_a, ts.ctx());
    fund.grant_token_for_test<MOCK_A>(mock_a_coin);

    assert_eq(get_existed_balance<SUI>(&fund), initial_sui);
    assert_eq(get_existed_balance<MOCK_A>(&fund), initial_mock_a);
    assert_eq(get_fund_total_shares(&fund), initial_sui);

    let trader = setup_trader(ts);

    (fund, trader)
}

#[test]
fun test_full_trade_lifecycle() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts);

    let buy_target_amount_b = 100u64;
    let buy_spend_sui = 5000u64;
    let sell_amount_a = 50u64;
    let sell_receive_sui = 2500u64;

    // 1. Grant Trade Capability & Create Order
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR); // Trader creates order
    let buy_order_map = create_test_order_pair(get<MOCK_B>(), buy_spend_sui, buy_target_amount_b);
    let sell_order_map = create_test_order_pair(get<MOCK_A>(), sell_receive_sui, sell_amount_a);
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );

    // 2. Verify and Prepare Exchange
    ts.next_tx(TRADER_ADDR);
    ts.return_to_sender(trader);
    let initial_sui = get_existed_balance<SUI>(&fund);
    let initial_mock_a = get_existed_balance<MOCK_A>(&fund);
    let initial_mock_b = get_existed_balance<MOCK_B>(&fund);
    let mut exchange = prepare_exchange(&mut ts, &mut fund, order);

    // Check fund balances after preparation
    assert_eq(get_existed_balance<SUI>(&fund), initial_sui - buy_spend_sui);
    assert_eq(get_existed_balance<MOCK_A>(&fund), initial_mock_a); // Not moved yet
    assert_eq(get_existed_balance<MOCK_B>(&fund), initial_mock_b);

    // 3. Execute Buy Order (Buy MOCK_B with SUI)

    ts.next_tx(TRADER_ADDR);
    let payment_mock_b: Coin<MOCK_B> = mint_for_testing(buy_target_amount_b, ts.ctx());
    fund::execute_buy<MOCK_B>(&mut exchange, payment_mock_b, ADMIN, &mut fund, ts.ctx());

    // Check fund balances after buy execution
    assert_eq(get_existed_balance<SUI>(&fund), initial_sui - buy_spend_sui);
    assert_eq(get_existed_balance<MOCK_B>(&fund), buy_target_amount_b);
    assert!(!exchange.exchange_contains_buy_order(&get<MOCK_B>()));
    assert_eq(exchange.get_exchange_held_sui_value(), 0);

    // 4. Execute Sell Order (Sell MOCK_A for SUI)
    ts.next_tx(TRADER_ADDR);
    let payment_sui: Coin<SUI> = mint_for_testing(sell_receive_sui, ts.ctx());
    fund::execute_sell<MOCK_A>(&mut exchange, payment_sui, ADMIN, &mut fund, ts.ctx());

    // Check fund balances after sell execution
    assert_eq(get_existed_balance<SUI>(&fund), initial_sui - buy_spend_sui + sell_receive_sui);
    assert_eq(get_existed_balance<MOCK_A>(&fund), initial_mock_a - sell_amount_a);
    assert!(!exchange.exchange_contains_sell_order(&get<MOCK_A>()));

    // 5. Finish Exchange
    ts.next_tx(TRADER_ADDR);
    fund::exchange_finish(exchange, &mut fund);

    ts::return_shared(fund);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InvalidOrder)]
fun test_verify_invalid_order_overlapping_keys() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts);

    // Grant Trade Cap & Create Order with overlapping keys
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let buy_order_map = create_test_order_pair(get<MOCK_A>(), 1000, 10); // Buy MOCK_A
    let sell_order_map = create_test_order_pair(get<MOCK_A>(), 5, 500); // Sell MOCK_A
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );

    // Verify and Prepare Exchange - Should fail
    ts.next_tx(ADMIN);
    let ex = prepare_exchange(&mut ts, &mut fund, order); // Aborts here

    ts::return_shared(fund);
    ts::return_shared(ex);
    ts.return_to_sender(trader);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::AssetNotFound)]
fun test_verify_invalid_order_sell_asset_not_found() {
    let mut ts = ts::begin(ADMIN);
    // Setup WITHOUT adding MOCK_B to the fund initially
    let mut fund = setup_fund(&mut ts);
    ts.next_tx(ADMIN);
    add_asset_type_for_testing<MOCK_A>(&mut fund); // Only add MOCK_A
    let _sui_cap = deposit_sui_for_user(&mut ts, &mut fund, ADMIN, 10000);
    ts.return_to_sender(_sui_cap);
    let trader = setup_trader(&mut ts);

    // Grant Trade Cap & Create Order trying to SELL MOCK_B
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let buy_order_map = vec_map::empty();
    let sell_order_map = create_test_order_pair(get<MOCK_B>(), 10, 1000); // Sell MOCK_B
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );

    // Verify and Prepare Exchange - Should fail
    ts.next_tx(ADMIN);
    let ex = prepare_exchange(&mut ts, &mut fund, order); // Aborts here

    ts::return_shared(fund);
    ts::return_shared(ex);
    ts.return_to_sender(trader);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InsufficentSUI)]
fun test_verify_insufficient_sui_reserve() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts); // Fund has 1M SUI

    // Grant Trade Cap & Create Order that tries to spend almost all SUI
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let sui_balance = get_existed_balance<SUI>(&fund);
    let spend_sui = sui_balance - RESERVE + 1; // Try to spend 1 more than allowed by reserve
    let buy_order_map = create_test_order_pair(get<MOCK_B>(), spend_sui, 1000);
    let sell_order_map = vec_map::empty();
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );

    // Verify and Prepare Exchange - Should fail
    ts.next_tx(ADMIN);
    let ex = prepare_exchange(&mut ts, &mut fund, order); // Aborts here

    ts::return_shared(fund);
    ts.return_to_sender(trader);
    ts::return_shared(ex);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InvalidExecution)]
fun test_execute_buy_invalid_payment() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts);

    let buy_target_amount_b = 100u64;
    let buy_spend_sui = 5000u64;

    // Grant Trade Cap, Create Order, Verify and Prepare
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let buy_order_map = create_test_order_pair(get<MOCK_B>(), buy_spend_sui, buy_target_amount_b);
    let sell_order_map = vec_map::empty();
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );
    ts.next_tx(ADMIN);
    let mut exchange = prepare_exchange(&mut ts, &mut fund, order);

    // Execute Buy with insufficient payment
    ts.next_tx(ADMIN); // Admin provides payment
    let payment_mock_b: Coin<MOCK_B> = mint_for_testing(buy_target_amount_b - 1, ts.ctx()); // Not enough
    fund::execute_buy<MOCK_B>(&mut exchange, payment_mock_b, ADMIN, &mut fund, ts.ctx()); // Aborts here

    // Cleanup (won't reach)
    ts::return_shared(exchange);
    ts::return_shared(fund);
    ts.return_to_sender(trader);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InvalidExecution)]
fun test_execute_sell_invalid_payment() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts);

    let sell_amount_a = 50u64;
    let sell_receive_sui = 2500u64;

    // Grant Trade Cap, Create Order, Verify and Prepare
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let buy_order_map = vec_map::empty();
    let sell_order_map = create_test_order_pair(get<MOCK_A>(), sell_receive_sui, sell_amount_a);
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );
    ts.next_tx(ADMIN);
    let mut exchange = prepare_exchange(&mut ts, &mut fund, order);

    // Execute Sell with insufficient SUI payment
    ts.next_tx(ADMIN); // Admin provides payment
    let payment_sui: Coin<SUI> = mint_for_testing(sell_receive_sui - 1, ts.ctx()); // Not enough
    fund::execute_sell<MOCK_A>(&mut exchange, payment_sui, ADMIN, &mut fund, ts.ctx()); // Aborts here

    // Cleanup (won't reach)
    ts::return_shared(exchange);
    ts::return_shared(fund);
    ts.return_to_sender(trader);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::OrderRemains)]
fun test_exchange_finish_with_remaining_orders() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts);

    // Grant Trade Cap, Create Order, Verify and Prepare
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let buy_order_map = create_test_order_pair(get<MOCK_B>(), 5000, 100);
    let sell_order_map = create_test_order_pair(get<MOCK_A>(), 2500, 50); // Corrected sell order args
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );
    ts.next_tx(ADMIN);
    let exchange = prepare_exchange(&mut ts, &mut fund, order);

    // Try to finish exchange WITHOUT executing orders
    ts.next_tx(ADMIN);
    fund::exchange_finish(exchange, &mut fund); // Aborts here

    // Cleanup (won't reach)
    ts::return_shared(fund);
    ts.return_to_sender(trader);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::InsufficentSUI)]
fun test_update_policy_and_verify_fail() {
    let mut ts = ts::begin(ADMIN);
    let (mut fund, trader) = setup_trading_environment(&mut ts); // Fund has 1M SUI

    // Update policy to require 50% SUI reserve
    ts.next_tx(ADMIN);
    fund::update_policy(&mut fund, 50); // 50% reserve

    // Grant Trade Cap & Create Order that tries to spend more than 50% SUI
    let trade_cap = grant_trade_cap(&mut ts, &fund, &trader);
    ts.next_tx(TRADER_ADDR);
    let sui_balance = get_existed_balance<SUI>(&fund);
    let total_shares = get_fund_total_shares(&fund);
    let required_reserve_abs = 50 * total_shares / 100; // Calculate absolute reserve
    let spend_sui = sui_balance - required_reserve_abs + 1; // Try to spend 1 more than allowed
    let buy_order_map = create_test_order_pair(get<MOCK_B>(), spend_sui, 1000);
    let sell_order_map = vec_map::empty();
    let order = create_test_order(
        &mut ts,
        &fund,
        &trader,
        trade_cap,
        buy_order_map,
        sell_order_map,
    );

    // Verify and Prepare Exchange - Should fail due to policy
    ts.next_tx(ADMIN);
    let ex = prepare_exchange(&mut ts, &mut fund, order); // Aborts here

    ts::return_shared(fund);
    ts.return_to_sender(trader);
    ts::return_shared(ex);
    ts.end();
}
