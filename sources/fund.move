module obj_cap::fund;

use std::type_name::{get, TypeName};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::dynamic_field::{add, borrow_mut, borrow};
use sui::event;
use sui::object::id;
use sui::sui::SUI;

#[error]
const FundMismatch: vector<u8> = b"Fund Id are not mathching";

#[error]
const InsufficentSUI: vector<u8> = b"Insufficent SUI, Consider rebase portfolio first";

#[error]
const InsufficientDeposit: vector<u8> = b"Value must be greater than minimum decreases";

/// Event for withdrawal auditing
public struct WithdrawEvent has copy, drop, store {
    fund_id: ID,
    amount: u64,
    recipient: address,
}

/// The main shared fund object
public struct Fund has key {
    id: UID,
    shares: u64,
    asset_lists: vector<TypeName>,
    gas_reserve: u64,
}

/// A one-time-use capability to withdraw a fixed amount
public struct WithdrawCap has key, store {
    id: UID,
    fund_id: ID,
    amount: u64,
}

/// Creates a new shared fund object with 0 balance
entry fun create(gas_reserve: u64, ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let asset_lists = vector::empty<TypeName>();

    let mut fund = Fund { id, shares: 0, asset_lists, gas_reserve };
    fund.add_asset_type<SUI>();

    let id = object::id(&fund);
    transfer::share_object(fund);
    id
}

/// Entry point: anyone can deposit SUI Coin into the fund
entry fun deposit(fund: &mut Fund, coins: Coin<SUI>, ctx: &mut TxContext) {
    // minimum deposit requirement
    assert!(coins.value() > fund.gas_reserve, InsufficientDeposit);

    let input = coin::into_balance(coins);
    let cap = grant_withdraw_cap(fund, input.value(), ctx);
    fund.shares = fund.shares + input.value();
    let balance = borrow_mut<TypeName, Balance<SUI>>(&mut fund.id, get<SUI>());
    balance.join(input);
    transfer::transfer(cap, ctx.sender());
}

/// Withdraw Coin<SUI> using a one-time WithdrawCap
entry fun withdraw(fund: &mut Fund, cap: WithdrawCap, recipient: address, ctx: &mut TxContext) {
    // Cap must be unused
    assert!(cap.fund_id==id(fund), FundMismatch); // Cap must match fund

    let total_shares = fund.shares;
    let gas_reserve = fund.gas_reserve;

    let sui_balance = update_existed_balance<SUI>(fund);
    let immediate_withdrawal = (sui_balance.value()*cap.amount)/total_shares;

    // Cap must be non-zero
    if (cap.amount < total_shares) {
        assert!(immediate_withdrawal <= sui_balance.value() - gas_reserve, InsufficentSUI);
    };

    let WithdrawCap { id, fund_id, amount } = cap;

    // immediately withraw sui balance
    transfer::public_transfer(
        sui_balance.split(immediate_withdrawal).into_coin(ctx),
        recipient,
    );

    fund.shares = fund.shares - amount;

    // trigger following liquidation through events
    event::emit(WithdrawEvent {
        fund_id,
        amount: amount,
        recipient,
    });

    // consume the capability
    id.delete();
}

/// Internal call to grant a capability — intended to be used only by trusted modules
fun grant_withdraw_cap(fund: &Fund, amount: u64, ctx: &mut TxContext): WithdrawCap {
    WithdrawCap {
        id: object::new(ctx),
        fund_id: id(fund),
        amount,
    }
}

/// Returns the fund balance
public fun get_fund_total_shares(fund: &Fund): u64 {
    fund.shares
}

public fun get_existed_balance<T>(fund: &Fund): u64 {
    assert!(fund.asset_lists.contains(&get<T>()), FundMismatch);
    borrow<TypeName, Balance<T>>(&fund.id, get<T>()).value()
}

fun add_asset_type<T>(fund: &mut Fund) {
    let name = get<T>();
    if (fund.asset_lists.contains(&name)) {
        return
    };
    fund.asset_lists.push_back(name);
    add(&mut fund.id, get<T>(), balance::zero<T>());
}

fun update_existed_balance<T>(fund: &mut Fund): &mut Balance<T> {
    assert!(fund.asset_lists.contains(&get<T>()), FundMismatch);
    borrow_mut<TypeName, Balance<T>>(&mut fund.id, get<T>())
}

#[test_only]
public fun get_withdraw_cap_amount(cap: &WithdrawCap): u64 {
    cap.amount
}

#[test_only]
public fun get_withdraw_cap_fund_id(cap: &WithdrawCap): ID {
    cap.fund_id
}
