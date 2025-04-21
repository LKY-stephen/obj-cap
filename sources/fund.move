module obj_cap::fund;

use std::type_name::{get, TypeName};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::dynamic_field::{add, borrow_mut, borrow};
use sui::event;
use sui::object::id;
use sui::sui::SUI;
use sui::transfer::{public_transfer, share_object};
use sui::vec_map::VecMap;

// --- Errors ---

#[error]
// Error when an operation involves mismatched Fund IDs.
const FundMismatch: vector<u8> = b"Fund Id are not mathching";

#[error]
// Error when the fund lacks sufficient SUI for an operation, potentially after accounting for reserves.
const InsufficentSUI: vector<u8> = b"Insufficent SUI, Consider rebase portfolio first";

#[error]
// Error when a deposit amount is below the required minimum (gas_reserve).
const InsufficientDeposit: vector<u8> = b"Value must be greater than minimum decreases";

#[error]
// Error when a proposed trade Order fails validation checks (e.g., overlapping buy/sell assets).
const InvalidOrder: vector<u8> = b"Order validation failed";

#[error]
// Error when the details of a trade execution (e.g., received amount) don't match the corresponding order.
const InvalidExecution: vector<u8> = b"Execution does not match the order";

#[error]
// Error when an asset type specified in an order is not registered within the fund.
const AssetNotFound: vector<u8> = b"Asset type not found in fund or order";

#[error]
// Error when attempting to finalize an Exchange object that still contains pending buy or sell orders.
const OrderRemains: vector<u8> = b"The exchange still has orders";

#[error]
// Error when trying to execute a trade for an asset pair not present in the Exchange object's orders.
const ExchangePairNotFound: vector<u8> = b"Specified asset pair not found in the exchange order";

// --- Events ---

/// Event emitted when a withdrawal occurs, for auditing purposes.
public struct WithdrawEvent has copy, drop, store {
    fund_id: ID,
    /// The amount of shares withdrawn.
    amount: u64,
    /// The address receiving the withdrawn assets.
    recipient: address,
}

// --- Structs ---

/// Represents the core shared fund object.
/// Holds the total shares, registered asset types, SUI reserve, and optional policy.
public struct Fund has key {
    id: UID,
    // Total number of shares representing ownership in the fund.
    shares: u64,
    // List of asset types the fund can hold.
    asset_lists: vector<TypeName>,
    // Minimum SUI balance to maintain for gas fees.
    gas_reserve: u64,
    // Optional policy defining operational rules (e.g., reserve percentage).
    policy: Option<Policy>,
}

/// A single-use capability object granting the holder the right to withdraw
/// a specific amount of shares from the fund.
public struct WithdrawCap has key, store {
    id: UID,
    fund_id: ID,
    // The number of shares this capability allows withdrawing.
    amount: u64,
}

// grant one time trade capability to a trader
public struct TradeCap has key, store {
    id: UID,
    fund_id: ID,
    trader_id: ID,
}

/// Represents a trader entity authorized to interact with the fund's trading mechanisms.
public struct Trader has key, store {
    id: UID,
}

/// Represents a trading pair within an Order or Exchange.
/// `base`: Amount of the asset being spent (SUI for buys, Token for sells).
/// `target`: Amount of the asset expected to be received (Token for buys, SUI for sells).
public struct Pair has copy, drop, store {
    base: u64,
    target: u64,
}

/// Represents a proposed set of buy and sell orders for the fund.
/// This object is submitted for verification before becoming an Exchange.
public struct Order has key, store {
    id: UID,
    fund_id: ID,
    /// Map where key is the TypeName of the asset to buy,
    /// and value is a Pair { sui_to_spend, target_token_to_receive }.
    buy: VecMap<TypeName, Pair>,
    /// Map where key is the TypeName of the asset to sell,
    /// and value is a Pair { token_to_sell, sui_to_receive }.
    sell: VecMap<TypeName, Pair>,
}

/// Defines operational rules and constraints for the fund, particularly for validating Orders.
public struct Policy has drop, store {
    /// The minimum percentage of the fund's total value (in shares) that must be
    /// maintained as SUI reserve after accounting for potential SUI spending in an order.
    min_sui_reserve_percentage: u64, // e.g., 10 means 10%
}

/// Holds assets withdrawn from the fund, ready for execution on external exchanges.
/// Contains the specific buy/sell orders derived from a verified Order object.
public struct Exchange has key, store {
    id: UID,
    fund_id: ID,
    /// Buy orders to be executed. Map<AssetToBuy, Pair{SuiToSpend, AssetToReceive}>.
    buy_orders: VecMap<TypeName, Pair>,
    /// Sell orders to be executed. Map<AssetToSell, Pair{AssetToSell, SuiToReceive}>.
    sell_orders: VecMap<TypeName, Pair>,
    /// SUI balance withdrawn from the fund specifically to fulfill the buy orders.
    held_sui_balance: Balance<SUI>,
}

// --- Functions ---

/// Creates a new, empty Fund object and shares it.
/// Initializes with a specified gas reserve and registers SUI as the first asset type.
public(package) entry fun create(gas_reserve: u64, ctx: &mut TxContext) {
    let asset_lists = vector::empty<TypeName>();
    let mut fund = Fund {
        id: object::new(ctx),
        shares: 0,
        asset_lists,
        gas_reserve,
        policy: option::none(),
    };
    fund.add_asset_type<SUI>();
    transfer::share_object(fund);
}

/// Allows anyone to deposit SUI into the fund.
/// Increases the fund's SUI balance and total shares.
/// Grants the depositor a WithdrawCap corresponding to their deposited amount.
/// Requires deposit amount to be greater than the fund's gas_reserve.
public(package) entry fun deposit(fund: &mut Fund, coins: Coin<SUI>, ctx: &mut TxContext) {
    // minimum deposit requirement
    assert!(coins.value() > fund.gas_reserve, InsufficientDeposit);

    let input = coin::into_balance(coins);
    let cap = grant_withdraw_cap(fund, input.value(), ctx);
    fund.shares = fund.shares + input.value();
    let balance = borrow_mut<TypeName, Balance<SUI>>(&mut fund.id, get<SUI>());
    balance.join(input);
    transfer::transfer(cap, ctx.sender());
}

/// Allows withdrawing assets (currently only SUI) from the fund using a WithdrawCap.
/// Calculates the proportional SUI amount based on the cap's share amount.
/// Ensures sufficient SUI remains after withdrawal, respecting the gas reserve.
/// Emits a WithdrawEvent and consumes the WithdrawCap.
public(package) entry fun withdraw(
    fund: &mut Fund,
    cap: WithdrawCap,
    recipient: address,
    ctx: &mut TxContext,
) {
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

/// Internal helper function to create and return a WithdrawCap.
/// Intended for use only within this module or trusted modules.
fun grant_withdraw_cap(fund: &Fund, amount: u64, ctx: &mut TxContext): WithdrawCap {
    WithdrawCap {
        id: object::new(ctx),
        fund_id: id(fund),
        amount,
    }
}

/// Returns the total number of shares currently issued by the fund.
public fun get_fund_total_shares(fund: &Fund): u64 {
    fund.shares
}

/// Returns the current balance of a specific asset type `T` held by the fund.
/// Asserts that the asset type `T` is registered in the fund's `asset_lists`.
public fun get_existed_balance<T>(fund: &Fund): u64 {
    assert!(fund.asset_lists.contains(&get<T>()), FundMismatch);
    borrow<TypeName, Balance<T>>(&fund.id, get<T>()).value()
}

/// Grants a TradeCap to a specified Trader, allowing them to create Orders for the fund.
/// Placeholder for potential future permission checks. Shares the TradeCap.
public fun grant_trade(fund: &Fund, trader: &Trader, ctx: &mut TxContext) {
    // add some permision or policy check here.
    share_object(TradeCap {
        id: object::new(ctx),
        fund_id: id(fund),
        trader_id: id(trader),
    });
}

/// Internal helper to add a new asset type `T` to the fund's `asset_lists`
/// and initialize its balance field (as a dynamic field) to zero.
/// Does nothing if the asset type is already registered.
fun add_asset_type<T>(fund: &mut Fund) {
    let name = get<T>();
    if (fund.asset_lists.contains(&name)) {
        return
    };
    fund.asset_lists.push_back(name);
    add(&mut fund.id, name, balance::zero<T>());
}

/// Internal helper to get a mutable reference to the balance of an existing asset type `T`.
/// Asserts that the asset type `T` is registered in the fund.
fun update_existed_balance<T>(fund: &mut Fund): &mut Balance<T> {
    assert!(fund.asset_lists.contains(&get<T>()), FundMismatch);
    borrow_mut<TypeName, Balance<T>>(&mut fund.id, get<T>())
}

/// Verifies a submitted Order against the fund's state and policy (if any).
/// Checks for valid asset types, disjoint buy/sell orders, and sufficient SUI reserves.
/// If valid, creates and shares an Exchange object, withdrawing the necessary SUI
/// from the fund to cover buy orders. Consumes the original Order object.
public(package) entry fun verify_and_prepare_exchange(
    fund: &mut Fund,
    order: Order,
    ctx: &mut TxContext,
) {
    let Order { id: order_id, fund_id, buy, sell } = order;
    assert!(fund_id == id(fund), FundMismatch);
    let fund_sui_balance_ref = borrow<TypeName, Balance<SUI>>(&fund.id, get<SUI>());
    let initial_sui_value = fund_sui_balance_ref.value();
    let mut total_sui_to_spend: u64 = 0;
    let mut total_sui_to_get: u64 = 0;

    // Validate disjoint keys and calculate SUI changes
    let buy_keys = buy.keys();
    let sell_keys = sell.keys();

    // Check buy orders
    buy_keys.do!(|key| {
        // Ensure buy keys are not in sell keys
        assert!(!sell.contains(&key), InvalidOrder);
        // Ensure asset type exists in fund for potential future deposits
        assert!(fund.asset_lists.contains(&key), AssetNotFound);
        let pair = buy.get(&key);
        total_sui_to_spend = total_sui_to_spend + pair.base;
    });

    // Check buy orders and calculate SUI gain
    // Check buy orders
    sell_keys.do!(|key| {
        // Ensure asset type exists in fund for potential future deposits
        assert!(fund.asset_lists.contains(&key), AssetNotFound);
        let pair = sell.get(&key);
        total_sui_to_get = total_sui_to_get + pair.base;
    });

    // Validate SUI reserve percentage
    let reserve = if (fund.policy.is_none()) {
        fund.gas_reserve
    } else {
        fund.policy.borrow().min_sui_reserve_percentage*fund.shares/100
    };
    assert!(initial_sui_value+total_sui_to_get>=total_sui_to_spend+reserve, InsufficentSUI);

    // Prepare Exchange object - Withdraw only necessary SUI
    let fund_sui_balance = update_existed_balance<SUI>(fund);
    let held_sui = fund_sui_balance.split(total_sui_to_spend);

    let exchange = Exchange {
        id: object::new(ctx),
        fund_id: object::id(fund),
        buy_orders: buy, // Transfer ownership
        sell_orders: sell, // Transfer ownership
        held_sui_balance: held_sui,
    };

    // Consume the order object ID
    order_id.delete();

    // Transfer exchange object to sender or make it shared? Transferring for now.
    share_object(exchange);
}

/// Executes a specific buy trade listed in the Exchange object.
/// Requires the payment (received `Target` asset) and the recipient address for the SUI.
/// Removes the corresponding buy order from the Exchange.
/// Deposits the received `Target` asset into the fund.
/// Transfers the spent SUI from the Exchange's held balance to the recipient.
/// Asserts that the received payment meets or exceeds the expected amount.
/// Note: This is a simplified placeholder; real execution would involve DEX interaction.
entry fun execute_buy<Target>(
    exchange: &mut Exchange,
    payment: Coin<Target>, // The asset received from the external exchange
    recipient: address, // The address (e.g., DEX pool) to send the SUI payment to
    fund: &mut Fund,
    ctx: &mut TxContext,
) {
    assert!(exchange.fund_id == id(fund), FundMismatch);
    let type_name = get<Target>();
    assert!(exchange.buy_orders.contains(&type_name), ExchangePairNotFound);

    let (_, pair) = exchange.buy_orders.remove(&type_name);

    assert!(exchange.held_sui_balance.value() >= pair.base, InsufficentSUI);
    assert!(payment.value()>= pair.target, InvalidExecution);

    fund.update_existed_balance<Target>().join(payment.into_balance());

    public_transfer(exchange.held_sui_balance.split(pair.base).into_coin(ctx), recipient);
}

/// Updates or sets the fund's operational policy.
public fun update_policy(fund: &mut Fund, min_sui_reserve_percentage: u64) {
    let policy = Policy {
        min_sui_reserve_percentage,
    };
    fund.policy = option::some(policy);
}

/// Executes a specific sell trade listed in the Exchange object.
/// Requires the payment (received SUI) and the recipient address for the `Target` asset.
/// Removes the corresponding sell order from the Exchange.
/// Deposits the received SUI into the fund.
/// Withdraws the `Target` asset from the fund and transfers it to the recipient.
/// Asserts that the received SUI payment meets or exceeds the expected amount.
/// Note: This is a simplified placeholder; real execution would involve DEX interaction.
entry fun execute_sell<Target>(
    exchange: &mut Exchange,
    payment: Coin<SUI>, // The SUI received from the external exchange
    recipient: address, // The address (e.g., DEX pool) to send the sold asset to
    fund: &mut Fund,
    ctx: &mut TxContext,
) {
    assert!(exchange.fund_id == id(fund), FundMismatch);
    let type_name = get<Target>();
    assert!(exchange.sell_orders.contains(&type_name), ExchangePairNotFound);
    let (_, pair) = exchange.sell_orders.remove(&type_name);

    assert!(payment.value()>= pair.base, InvalidExecution);

    fund.update_existed_balance<SUI>().join(payment.into_balance());

    public_transfer(
        fund.update_existed_balance<Target>().split(pair.target).into_coin(ctx),
        recipient,
    );
}

/// Finalizes an Exchange object after all its orders have been executed.
/// Asserts that both buy and sell order lists are empty.
/// Returns any remaining held SUI back to the fund.
/// Destroys the empty order maps and the Exchange object itself.
public entry fun exchange_finish(exchange: Exchange, fund: &mut Fund) {
    assert!(exchange.buy_orders.is_empty() && exchange.sell_orders.is_empty(), OrderRemains);
    let Exchange { id, fund_id: _, buy_orders, sell_orders, held_sui_balance } = exchange;
    // Return any remaining held SUI
    if (held_sui_balance.value() > 0) {
        let fund_sui_balance = update_existed_balance<SUI>(fund);
        fund_sui_balance.join(held_sui_balance);
    } else {
        held_sui_balance.destroy_zero();
    };
    // Destroy empty vector maps
    buy_orders.destroy_empty();
    sell_orders.destroy_empty();
    // Delete the Exchange object wrapper
    id.delete();
    return
}

// --- Test-Only Functions ---

#[test_only]
/// Returns the amount associated with a WithdrawCap.
public fun get_withdraw_cap_amount(cap: &WithdrawCap): u64 {
    cap.amount
}

#[test_only]
/// Returns the fund ID associated with a WithdrawCap.
public fun get_withdraw_cap_fund_id(cap: &WithdrawCap): ID {
    cap.fund_id
}

#[test_only]
/// Creates a new Trader object and transfers it to the sender.
public fun create_trader(ctx: &mut TxContext) {
    let trader = Trader {
        id: object::new(ctx),
    };
    public_transfer(trader, ctx.sender());
}

#[test_only]
/// Creates a VecMap containing a single asset pair for testing Orders.
public fun create_test_order_pair(name: TypeName, base: u64, target: u64): VecMap<TypeName, Pair> {
    use sui::vec_map::empty;
    let mut order_pair = empty();
    order_pair.insert(name, Pair { base, target });
    order_pair
}

#[test_only]
/// Creates and shares an Order object using a TradeCap for testing.
/// Consumes the TradeCap.
public fun create_order(
    fund: &Fund,
    trader: &Trader,
    tradeCap: TradeCap,
    buy_order: VecMap<TypeName, Pair>,
    sell_order: VecMap<TypeName, Pair>,
    ctx: &mut TxContext,
) {
    assert!(tradeCap.fund_id == id(fund), FundMismatch);
    assert!(tradeCap.trader_id == id(trader), FundMismatch);

    let TradeCap { id, fund_id, .. } = tradeCap;

    let order = Order {
        id: object::new(ctx),
        fund_id,
        buy: buy_order,
        sell: sell_order,
    };

    share_object(order);
    id.delete();
}

#[test_only]
/// Adds an asset type to the fund for testing purposes.
public fun add_asset_type_for_testing<T>(fund: &mut Fund) {
    add_asset_type<T>(fund);
}

// --- New Test-Only Helper Functions ---

#[test_only]
/// Returns the value of the SUI held in the exchange.
public fun get_exchange_held_sui_value(exchange: &Exchange): u64 {
    exchange.held_sui_balance.value()
}

#[test_only]
/// Checks if the exchange contains a buy order for the given asset type.
public fun exchange_contains_buy_order(exchange: &Exchange, type_name: &TypeName): bool {
    exchange.buy_orders.contains(type_name)
}

#[test_only]
/// Checks if the exchange contains a sell order for the given asset type.
public fun exchange_contains_sell_order(exchange: &Exchange, type_name: &TypeName): bool {
    exchange.sell_orders.contains(type_name)
}

#[test_only]
/// Deposits a coin of type T directly into the fund's balance for testing.
/// Asserts the asset type is already registered.
public fun grant_token_for_test<T>(fund: &mut Fund, coin: Coin<T>) {
    assert!(fund.asset_lists.contains(&get<T>()), FundMismatch);
    update_existed_balance<T>(fund).join(coin.into_balance());
}

#[test_only]
/// Returns the configured policy reserve percentage, or 0 if no policy is set.
public fun get_policy_reserve_percentage(fund: &Fund): u64 {
    if (fund.policy.is_some()) {
        fund.policy.borrow().min_sui_reserve_percentage
    } else {
        0 // Or handle as error/option if preferred
    }
}

#[test_only]
/// Returns a mutable reference to the balance of the specified asset type in the fund for testing.
public fun get_balance_for_Test<T>(fund: &mut Fund): &mut Balance<T> {
    update_existed_balance<T>(fund)
}

#[test_only]
/// Calculates the effective SUI reserve amount based on policy or gas_reserve for testing.
/// Handles potential overflows and division by zero.
public fun get_effective_reserve(fund: &Fund): u64 {
    if (fund.policy.is_none()) {
        fund.gas_reserve
    } else {
        // Ensure calculation doesn't overflow and handles potential division by zero if shares are 0
        let policy = fund.policy.borrow();
        if (fund.shares == 0) {
            0 // Or fund.gas_reserve depending on desired logic for zero shares
        } else {
            // Consider using u128 for intermediate calculation if shares * percentage can exceed u64::MAX
            ((policy.min_sui_reserve_percentage as u128) * (fund.shares as u128) / 100) as u64
        }
    }
}
