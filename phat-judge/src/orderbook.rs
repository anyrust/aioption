//! High-Performance Order Book Matching Engine
//!
//! Data structures:
//!   BTreeMap<Price, Vec<OrderId>> — sorted by price, same price stored in Vec (FIFO)
//!   Bids: BTreeMap iterated in reverse — price high to low
//!   Asks: BTreeMap — price low to high
//!
//! Matching rules:
//!   1. Price priority (highest bid first, lowest ask first)
//!   2. Time priority (first order at same price gets filled first)
//!   3. Partial fill support (remaining quantity stays in the book)

use std::collections::{BTreeMap, HashMap};
use serde::{Deserialize, Serialize};

/// Order
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: u64,
    pub maker: String,          // 0x... Ethereum address
    pub option_index: usize,    // Option index
    pub is_bid: bool,           // true=buy, false=sell
    pub price: u128,            // Price per share (wei)
    pub amount: u128,           // Original order quantity (share-units = wei)
    pub filled: u128,           // Filled quantity
    pub timestamp: u64,         // Unix milliseconds
}

/// Order book for a single option
#[derive(Debug, Clone, Default)]
pub struct OptionBook {
    /// Bid queue: <price, Vec<order_id>>  high→low
    pub bids: BTreeMap<u128, Vec<u64>>,
    /// Ask queue: <price, Vec<order_id>>  low→high
    pub asks: BTreeMap<u128, Vec<u64>>,
}

/// Order book engine
pub struct OrderBookEngine {
    /// All orders (order_id → Order)
    pub orders: HashMap<u64, Order>,
    /// Order book for each option
    pub books: Vec<OptionBook>,
    /// User positions: user → option_index → shares
    pub positions: HashMap<String, Vec<u128>>,
    /// User available balance (wei)
    pub balances: HashMap<String, u128>,
    /// User active order ID list
    pub user_order_ids: HashMap<String, Vec<u64>>,
    /// Next order ID
    next_id: u64,
    /// Number of options
    option_count: usize,
}

/// Trade record
#[derive(Debug, Clone, Serialize)]
pub struct Trade {
    pub buy_order_id: u64,
    pub sell_order_id: u64,
    pub buyer: String,
    pub seller: String,
    pub option_index: usize,
    pub price: u128,
    pub amount: u128,
    pub timestamp: u64,
}

/// Place order response
#[derive(Debug, Serialize)]
pub struct PlaceOrderResult {
    pub order_id: u64,          // 0 = fully filled immediately
    pub filled: u128,           // Immediate filled amount
    pub remaining: u128,        // Remaining order quantity
    pub trades: Vec<Trade>,     // Trade records
}

impl OrderBookEngine {
    pub fn new(option_count: usize) -> Self {
        Self {
            orders: HashMap::new(),
            books: (0..option_count).map(|_| OptionBook::default()).collect(),
            positions: HashMap::new(),
            balances: HashMap::new(),
            user_order_ids: HashMap::new(),
            next_id: 1,
            option_count,
        }
    }

    fn now_ms() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
    }

    fn next_order_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// User deposit (synced from on-chain deposit event)
    pub fn deposit(&mut self, user: &str, amount: u128) {
        *self.balances.entry(user.to_string()).or_insert(0) += amount;
    }

    /// User withdrawal (requires TEE signature for actual transfer)
    pub fn withdraw(&mut self, user: &str, amount: u128) -> bool {
        let bal = self.balances.entry(user.to_string()).or_insert(0);
        if *bal < amount { return false; }
        *bal -= amount;
        true
    }

    /// Place limit buy order
    pub fn place_buy(&mut self, maker: &str, option: usize, price: u128, amount: u128) -> PlaceOrderResult {
        let total_cost = (price * amount) / 1_000_000_000_000_000_000u128;
        let bal = self.balances.entry(maker.to_string()).or_insert(0);
        if *bal < total_cost {
            return PlaceOrderResult { order_id: 0, filled: 0, remaining: amount, trades: vec![] };
        }
        *bal -= total_cost;  // Lock funds

        let mut remaining = amount;
        let mut trades = Vec::new();
        let mut filled = 0u128;

        // Match sell orders (price low→high)
        let book = &mut self.books[option];
        let ask_prices: Vec<u128> = book.asks.keys().copied().collect();
        let mut to_remove = Vec::new();

        for ask_price in ask_prices {
            if ask_price > price || remaining == 0 { break; }

            if let Some(order_ids) = book.asks.get_mut(&ask_price) {
                let mut i = 0;
                while i < order_ids.len() && remaining > 0 {
                    let oid = order_ids[i];
                    if let Some(ask) = self.orders.get_mut(&oid) {
                        let ask_remain = ask.amount - ask.filled;
                        if ask_remain == 0 { i += 1; continue; }

                        let match_amt = remaining.min(ask_remain);
                        let cost = (ask_price * match_amt) / 1_000_000_000_000_000_000u128;

                        // Seller receives ETH
                        *self.balances.entry(ask.maker.clone()).or_insert(0) += cost;
                        // Refund price difference to buyer
                        let refund = ((price - ask_price) * match_amt) / 1_000_000_000_000_000_000u128;
                        *self.balances.entry(maker.to_string()).or_insert(0) += refund;
                        // Transfer shares
                        self.positions.entry(maker.to_string()).or_insert_with(|| vec![0; self.option_count])[option] += match_amt;

                        ask.filled += match_amt;
                        remaining -= match_amt;
                        filled += match_amt;

                        trades.push(Trade {
                            buy_order_id: 0, sell_order_id: oid,
                            buyer: maker.to_string(), seller: ask.maker.clone(),
                            option_index: option, price: ask_price,
                            amount: match_amt, timestamp: Self::now_ms(),
                        });

                        if ask.filled >= ask.amount {
                            order_ids.remove(i);
                            self.remove_user_order(&ask.maker.clone(), oid);
                        } else {
                            i += 1;
                        }
                    } else {
                        i += 1;
                    }
                }
                if order_ids.is_empty() {
                    to_remove.push(ask_price);
                }
            }
        }

        for p in &to_remove {
            book.asks.remove(p);
        }

        // Remaining quantity becomes a resting buy order
        let order_id = if remaining > 0 {
            let id = self.next_order_id();
            let order = Order {
                id, maker: maker.to_string(), option_index: option,
                is_bid: true, price, amount: remaining, filled: 0,
                timestamp: Self::now_ms(),
            };
            let entry = book.bids.entry(price).or_default();
            // Bids need reverse iteration (price high→low).
            // BTreeMap defaults to ascending order. We reverse iterate when querying.
            entry.push(id);
            self.orders.insert(id, order);
            self.user_order_ids.entry(maker.to_string()).or_default().push(id);
            id
        } else {
            0
        };

        PlaceOrderResult { order_id, filled, remaining, trades }
    }

    /// Place limit sell order
    pub fn place_sell(&mut self, maker: &str, option: usize, price: u128, amount: u128) -> PlaceOrderResult {
        let pos = self.positions.entry(maker.to_string()).or_insert_with(|| vec![0; self.option_count]);
        if pos[option] < amount {
            return PlaceOrderResult { order_id: 0, filled: 0, remaining: amount, trades: vec![] };
        }
        pos[option] -= amount;  // Lock shares

        let mut remaining = amount;
        let mut trades = Vec::new();
        let mut filled = 0u128;

        // Match buy orders (price high→low, reverse iterate BTreeMap)
        let book = &mut self.books[option];
        let bid_prices: Vec<u128> = book.bids.keys().copied().rev().collect(); // high→low
        let mut to_remove = Vec::new();

        for bid_price in bid_prices {
            if bid_price < price || remaining == 0 { break; }

            if let Some(order_ids) = book.bids.get_mut(&bid_price) {
                let mut i = 0;
                while i < order_ids.len() && remaining > 0 {
                    let oid = order_ids[i];
                    if let Some(bid) = self.orders.get_mut(&oid) {
                        let bid_remain = bid.amount - bid.filled;
                        if bid_remain == 0 { i += 1; continue; }

                        let match_amt = remaining.min(bid_remain);
                        let revenue = (bid_price * match_amt) / 1_000_000_000_000_000_000u128;

                        // Seller receives ETH (executed at bid price)
                        *self.balances.entry(maker.to_string()).or_insert(0) += revenue;
                        // Buyer receives shares
                        self.positions.entry(bid.maker.clone()).or_insert_with(|| vec![0; self.option_count])[option] += match_amt;

                        bid.filled += match_amt;
                        remaining -= match_amt;
                        filled += match_amt;

                        trades.push(Trade {
                            buy_order_id: oid, sell_order_id: 0,
                            buyer: bid.maker.clone(), seller: maker.to_string(),
                            option_index: option, price: bid_price,
                            amount: match_amt, timestamp: Self::now_ms(),
                        });

                        if bid.filled >= bid.amount {
                            order_ids.remove(i);
                            self.remove_user_order(&bid.maker.clone(), oid);
                        } else {
                            i += 1;
                        }
                    } else {
                        i += 1;
                    }
                }
                if order_ids.is_empty() {
                    to_remove.push(bid_price);
                }
            }
        }

        for p in &to_remove {
            book.bids.remove(p);
        }

        let order_id = if remaining > 0 {
            let id = self.next_order_id();
            let order = Order {
                id, maker: maker.to_string(), option_index: option,
                is_bid: false, price, amount: remaining, filled: 0,
                timestamp: Self::now_ms(),
            };
            book.asks.entry(price).or_default().push(id);
            self.orders.insert(id, order);
            self.user_order_ids.entry(maker.to_string()).or_default().push(id);
            id
        } else {
            0
        };

        PlaceOrderResult { order_id, filled, remaining, trades }
    }

    /// Cancel order
    pub fn cancel_order(&mut self, maker: &str, order_id: u64) -> Option<(u128, u128)> {
        let order = self.orders.get_mut(&order_id)?;
        if order.maker != maker { return None; }
        let remaining = order.amount - order.filled;
        if remaining == 0 { return None; }

        let book = &mut self.books[order.option_index];
        if order.is_bid {
            // Refund locked funds
            let refund = (order.price * remaining) / 1_000_000_000_000_000_000u128;
            *self.balances.entry(maker.to_string()).or_insert(0) += refund;
            // Remove from bid queue
            if let Some(ids) = book.bids.get_mut(&order.price) {
                ids.retain(|&id| id != order_id);
                if ids.is_empty() { book.bids.remove(&order.price); }
            }
        } else {
            // Refund locked shares
            self.positions.entry(maker.to_string()).or_insert_with(|| vec![0; self.option_count])[order.option_index] += remaining;
            // Remove from ask queue
            if let Some(ids) = book.asks.get_mut(&order.price) {
                ids.retain(|&id| id != order_id);
                if ids.is_empty() { book.asks.remove(&order.price); }
            }
        }

        let refund = (order.price * remaining) / 1_000_000_000_000_000_000u128;
        order.filled = order.amount; // mark as fully filled/cancelled
        self.remove_user_order(maker, order_id);

        Some((refund, remaining))
    }

    /// Get order book depth (for frontend display)
    pub fn depth(&self, option: usize) -> (Vec<(u128, u128)>, Vec<(u128, u128)>) {
        let book = &self.books[option];
        let mut bids: Vec<(u128, u128)> = Vec::new();
        let mut asks: Vec<(u128, u128)> = Vec::new();

        // Bids: price high→low
        for (&price, ids) in book.bids.iter().rev() {
            let total: u128 = ids.iter()
                .filter_map(|id| self.orders.get(id))
                .map(|o| o.amount - o.filled)
                .sum();
            if total > 0 { bids.push((price, total)); }
        }

        // Asks: price low→high
        for (&price, ids) in book.asks.iter() {
            let total: u128 = ids.iter()
                .filter_map(|id| self.orders.get(id))
                .map(|o| o.amount - o.filled)
                .sum();
            if total > 0 { asks.push((price, total)); }
        }

        (bids, asks)
    }

    /// Calculate final settlement amount (winning option winners receive 1 ETH per share)
    pub fn calculate_settlement(&self, winning_option: usize) -> Vec<(String, u128)> {
        let mut payouts = Vec::new();
        for (user, positions) in &self.positions {
            let shares = positions.get(winning_option).copied().unwrap_or(0);
            let balance = self.balances.get(user).copied().unwrap_or(0);
            let total = shares + balance;
            if total > 0 {
                payouts.push((user.clone(), total));
            }
        }
        payouts
    }

    fn remove_user_order(&mut self, user: &str, order_id: u64) {
        if let Some(ids) = self.user_order_ids.get_mut(user) {
            ids.retain(|&id| id != order_id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_place_buy_full_match() {
        let mut engine = OrderBookEngine::new(2);
        engine.deposit("alice", 100_000_000_000_000_000_000); // 100 ETH
        engine.positions.insert("bob".into(), vec![100_000_000_000_000_000_000, 0]); // 100 shares of option 0
        engine.balances.insert("bob".into(), 0);

        // Bob sells 50 shares at 0.5 ETH
        let _ = engine.place_sell("bob", 0, 500_000_000_000_000_000, 50_000_000_000_000_000_000);
        // Alice buys at 0.6, should match at 0.5
        let result = engine.place_buy("alice", 0, 600_000_000_000_000_000, 50_000_000_000_000_000_000);

        assert_eq!(result.order_id, 0); // fully filled
        assert_eq!(result.filled, 50_000_000_000_000_000_000);
        assert_eq!(result.trades.len(), 1);
        assert_eq!(result.trades[0].price, 500_000_000_000_000_000); // matched at ask price
    }

    #[test]
    fn test_cancel_order() {
        let mut engine = OrderBookEngine::new(2);
        engine.deposit("alice", 100_000_000_000_000_000_000);
        let r = engine.place_buy("alice", 0, 600_000_000_000_000_000, 10_000_000_000_000_000_000);
        assert!(r.order_id > 0);
        let refund = engine.cancel_order("alice", r.order_id);
        assert!(refund.is_some());
    }
}
