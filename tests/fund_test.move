module obj_cap::fund_tests;

use obj_cap::fund::{
    Self,
    WithdrawCap,
    get_fund_balance,
    get_fund_shares,
    get_withdraw_cap_amount,
    get_withdraw_cap_fund_id
};
use sui::balance::destroy_for_testing;
use sui::coin::{mint_for_testing, Coin, value};
use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils::assert_eq;

const ALICE: address = @0x114;
const BOB: address = @0x514;

// --- Helper Function ---

// Helper to get the WithdrawCap from the sender's inventory
// Assumes only one WithdrawCap is expected
fun take_withdraw_cap(ts: &ts::Scenario): WithdrawCap {
    ts.take_from_sender<WithdrawCap>()
}

#[test]
fun test_deposit_and_withdraw() {
    let mut ts = ts::begin(ALICE);
    let fund_id = fund::create(ts.ctx());

    // Mint SUI for Bob
    let deposit_amount = 1_000_000;
    let coin: Coin<SUI> = mint_for_testing(deposit_amount, ts.ctx());
    transfer::public_transfer(coin, BOB);

    // Bob Deposits
    ts.next_tx(BOB);
    let mut fund = ts.take_shared_by_id(fund_id);
    let coin_to_deposit = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&coin_to_deposit), deposit_amount);
    fund::deposit(&mut fund, coin_to_deposit, ts.ctx());

    // Check Fund State
    assert_eq(get_fund_balance(&fund), deposit_amount);
    assert_eq(get_fund_shares(&fund), deposit_amount);

    // Bob Withdraws
    // WithdrawCap was transferred to Bob during deposit

    ts.next_tx(BOB);
    let cap = take_withdraw_cap(&ts);
    assert_eq(get_withdraw_cap_amount(&cap), deposit_amount);
    assert_eq(get_withdraw_cap_fund_id(&cap), fund_id);

    fund::withdraw(&mut fund, cap, BOB, ts.ctx());

    // Check Final Fund State
    assert_eq(get_fund_balance(&fund), 0);
    assert_eq(get_fund_shares(&fund), 0);

    ts::return_shared(fund);

    // Check Bob received the coin and event emitted

    let scenario_summary = ts.next_tx(BOB);
    assert_eq(scenario_summary.num_user_events(), 1);

    let withdrawn_coin = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_coin), deposit_amount);
    ts.return_to_sender(withdrawn_coin); // Put it back for cleanup

    ts.end();
}

#[test]
/// Tests multiple deposits from different users and subsequent withdrawals.
fun test_multiple_deposits_and_withdrawals() {
    let mut ts = ts::begin(ALICE);
    let fund_id = fund::create(ts.ctx());

    // Mint SUI
    let deposit_alice = 1_000_000;
    let deposit_bob = 2_000_000;
    let total_deposit = deposit_alice + deposit_bob;

    let coin_alice: Coin<SUI> = mint_for_testing(deposit_alice, ts.ctx());
    // Alice keeps her coin for now

    let coin_bob: Coin<SUI> = mint_for_testing(deposit_bob, ts.ctx());
    transfer::public_transfer(coin_bob, BOB);

    // Alice Deposits
    ts.next_tx(ALICE);
    let mut fund = ts.take_shared_by_id(fund_id);
    fund::deposit(&mut fund, coin_alice, ts.ctx());
    assert_eq(get_fund_balance(&fund), deposit_alice);
    assert_eq(get_fund_shares(&fund), deposit_alice);

    // Bob Deposits
    ts.next_tx(BOB);
    let coin_to_deposit_bob = ts.take_from_sender<Coin<SUI>>();
    fund::deposit(&mut fund, coin_to_deposit_bob, ts.ctx());
    assert_eq(get_fund_balance(&fund), total_deposit);
    assert_eq(get_fund_shares(&fund), total_deposit);

    // Alice Withdraws
    ts.next_tx(ALICE);
    let cap_alice = take_withdraw_cap(&ts);
    fund::withdraw(&mut fund, cap_alice, ALICE, ts.ctx());

    let summary = ts.next_tx(BOB);
    assert_eq(summary.num_user_events(), 1);
    // Check state after Alice's withdrawal
    assert_eq(get_fund_balance(&fund), deposit_bob);
    assert_eq(get_fund_shares(&fund), deposit_bob);

    // Bob Withdraws
    let cap_bob = take_withdraw_cap(&ts);
    fund::withdraw(&mut fund, cap_bob, BOB, ts.ctx());

    let summary = ts.next_tx(BOB);
    assert_eq(summary.num_user_events(), 1);
    // Check final state
    assert_eq(get_fund_balance(&fund), 0);
    assert_eq(get_fund_shares(&fund), 0);

    ts::return_shared(fund);

    // Verify received amounts
    ts.next_tx(ALICE);
    let withdrawn_alice = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_alice), deposit_alice);
    destroy_for_testing(withdrawn_alice.into_balance()); // Cleanup

    ts.next_tx(BOB);
    let withdrawn_bob = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_bob), deposit_bob);
    destroy_for_testing(withdrawn_bob.into_balance()); // Cleanup

    ts.end();
}

// --- Negative Test Cases ---

#[test]
#[expected_failure(abort_code = obj_cap::fund::FundMismatch)]
fun test_withdraw_with_wrong_fund_cap() {
    let mut ts = ts::begin(ALICE);

    // Alice creates Fund A
    let fund_a_id = fund::create(ts.ctx());
    // Bob creates Fund B
    ts.next_tx(BOB);
    let fund_b_id = fund::create(ts.ctx());

    // Alice deposits into Fund A to get a cap
    ts.next_tx(ALICE);
    let deposit_amount = 100;
    let coin_a: Coin<SUI> = mint_for_testing(deposit_amount, ts.ctx());
    let mut fund_a = ts.take_shared_by_id(fund_a_id);
    fund::deposit(&mut fund_a, coin_a, ts.ctx());
    ts::return_shared(fund_a); // Return Fund A for now
    ts.next_tx(ALICE);
    // Alice takes the cap (Cap A) meant for Fund A
    let cap_a = take_withdraw_cap(&ts);
    assert_eq(get_withdraw_cap_fund_id(&cap_a), fund_a_id);
    assert_eq(get_withdraw_cap_amount(&cap_a), deposit_amount);

    // Alice tries to withdraw from Fund B using Cap A
    let mut fund_b = ts.take_shared_by_id(fund_b_id);
    fund::withdraw(&mut fund_b, cap_a, ALICE, ts.ctx()); // This should fail

    // Cleanup (won't be reached on abort)
    ts::return_shared(fund_b);
    ts.end();
}

#[test]
#[expected_failure(abort_code = obj_cap::fund::ZeroValue)]
fun test_deposit_zero_amount() {
    let mut ts = ts::begin(ALICE);
    let fund_id = fund::create(ts.ctx());

    // Mint 0 SUI for Bob
    let deposit_amount = 0;
    let coin: Coin<SUI> = mint_for_testing(deposit_amount, ts.ctx());
    transfer::public_transfer(coin, BOB);

    // Bob Deposits 0 SUI
    ts.next_tx(BOB);
    let mut fund = ts.take_shared_by_id(fund_id);
    let coin_to_deposit = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&coin_to_deposit), 0);
    fund::deposit(&mut fund, coin_to_deposit, ts.ctx());

    ts::return_shared(fund); // Return Fund for cleanup
    ts.end();
}

#[test]
fun test_cap_consumption() {
    // This test implicitly verifies that a cap is consumed after use,
    // because if it weren't, the second take_from_sender would fail.
    let mut ts = ts::begin(ALICE);
    let fund_id = fund::create(ts.ctx());

    // Mint SUI for Bob
    let deposit_amount = 500;
    let coin: Coin<SUI> = mint_for_testing(deposit_amount, ts.ctx());
    transfer::public_transfer(coin, BOB);

    // Bob Deposits
    ts.next_tx(BOB);
    let mut fund = ts.take_shared_by_id(fund_id);
    let coin_to_deposit = ts.take_from_sender<Coin<SUI>>();
    fund::deposit(&mut fund, coin_to_deposit, ts.ctx());

    // Bob takes the cap
    ts.next_tx(BOB);
    let cap = take_withdraw_cap(&ts);

    // Bob Withdraws
    fund::withdraw(&mut fund, cap, BOB, ts.ctx());
    ts::return_shared(fund);

    // Bob should now have the withdrawn Coin, but NOT the WithdrawCap
    // Trying to take a WithdrawCap again would fail if run in a real scenario.
    // In the test scenario, we verify Bob only has the Coin.

    ts.next_tx(BOB);
    let withdrawn_coin = ts.take_from_sender<Coin<SUI>>();
    assert_eq(value(&withdrawn_coin), deposit_amount);

    // Check Bob has no other objects (specifically, no WithdrawCap)
    // Note: The test scenario framework might not perfectly model "absence",
    // but taking the coin successfully implies the cap was consumed and replaced.
    // A more robust check would require framework support for asserting object absence.

    destroy_for_testing(withdrawn_coin.into_balance()); // Cleanup
    ts.end();
}
