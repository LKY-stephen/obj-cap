module obj_cap::fund;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::id;
use sui::sui::SUI;

#[error]
const FundMismatch: vector<u8> = b"Fund Id are not mathching";

#[error]
const InsufficentShares: vector<u8> = b"Insufficent shares";

#[error]
const ZeroValue: vector<u8> = b"Value must be greater than zero";

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
    balance: Balance<SUI>,
}

/// A one-time-use capability to withdraw a fixed amount
public struct WithdrawCap has key, store {
    id: UID,
    fund_id: ID,
    amount: u64,
    recipient: address,
}

/// Creates a new shared fund object with 0 balance
public fun create(ctx: &mut TxContext): ID {
    let id = object::new(ctx);
    let balance = balance::zero<SUI>();
    let fund = Fund { id, shares: 0, balance };
    let id = object::id(&fund);
    transfer::share_object(fund);
    id
}

/// Entry point: anyone can deposit SUI Coin into the fund
entry fun deposit(fund: &mut Fund, coins: Coin<SUI>, ctx: &mut TxContext) {
    assert!(coins.value() > 0, ZeroValue);

    let depositer = ctx.sender();
    let balance = coin::into_balance(coins);
    let cap = grant_withdraw_cap(fund, balance.value(), depositer, ctx);
    fund.shares = fund.shares + balance.value();
    fund.balance.join(balance);

    transfer::transfer(cap, depositer);
}

/// Withdraw Coin<SUI> using a one-time WithdrawCap
entry fun withdraw(fund: &mut Fund, cap: WithdrawCap, ctx: &mut TxContext) {
    // Cap must be unused
    assert!(cap.fund_id==id(fund), FundMismatch); // Cap must match fund

    assert!(cap.amount > 0, ZeroValue); // Cap must be non-zero
    assert!(cap.amount <= fund.shares, InsufficentShares);

    let WithdrawCap { id, fund_id, amount, recipient } = cap;

    let returned = (fund.balance.value()*amount).divide_and_round_up(fund.shares);

    let coin = fund.balance.split(returned).into_coin(ctx);

    fund.shares = fund.shares - amount;

    transfer::public_transfer(coin, recipient);

    event::emit(WithdrawEvent {
        fund_id,
        amount: amount,
        recipient,
    });

    // consume the capability
    id.delete();
}

/// Internal call to grant a capability — intended to be used only by trusted modules
fun grant_withdraw_cap(
    fund: &Fund,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
): WithdrawCap {
    WithdrawCap {
        id: object::new(ctx),
        fund_id: id(fund),
        amount,
        recipient,
    }
}

/// Returns the fund balance
public fun balance(fund: &Fund): u64 {
    fund.balance.value()
}
