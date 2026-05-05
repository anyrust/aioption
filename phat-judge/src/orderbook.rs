//! 高性能訂單簿撮合引擎
//!
//! 資料結構:
//!   BTreeMap<Price, Vec<OrderId>> — 按價格排序，同價用 Vec 存（FIFO）
//!   買單: Reverse<BTreeMap> — 價格從高到低
//!   賣單: BTreeMap — 價格從低到高
//!
//! 撮合規則:
//!   1. 價格優先（買單最高價優先，賣單最低價優先）
//!   2. 時間優先（同價先下單先吃）
//!   3. 部分成交支持（剩餘量保留掛單）

use std::collections::{BTreeMap, HashMap};
use serde::{Deserialize, Serialize};

/// 訂單
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Order {
    pub id: u64,
    pub maker: String,          // 0x... 以太坊地址
    pub option_index: usize,    // 選項索引
    pub is_bid: bool,           // true=買, false=賣
    pub price: u128,            // 每股價格 (wei)
    pub amount: u128,           // 原始下單量 (share-units = wei)
    pub filled: u128,           // 已成交量
    pub timestamp: u64,         // Unix 毫秒
}

/// 單個選項的訂單簿
#[derive(Debug, Clone, Default)]
pub struct OptionBook {
    /// 買單隊列: <price, Vec<order_id>>  價格高→低
    pub bids: BTreeMap<u128, Vec<u64>>,
    /// 賣單隊列: <price, Vec<order_id>>  價格低→高
    pub asks: BTreeMap<u128, Vec<u64>>,
}

/// 訂單簿引擎
pub struct OrderBookEngine {
    /// 所有訂單 (order_id → Order)
    pub orders: HashMap<u64, Order>,
    /// 每個選項的訂單簿
    pub books: Vec<OptionBook>,
    /// 用戶持倉: user → option_index → shares
    pub positions: HashMap<String, Vec<u128>>,
    /// 用戶可用餘額 (wei)
    pub balances: HashMap<String, u128>,
    /// 用戶活躍訂單 ID 列表
    pub user_order_ids: HashMap<String, Vec<u64>>,
    /// 下一個訂單 ID
    next_id: u64,
    /// 選項數量
    option_count: usize,
}

/// 成交記錄
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

/// 掛單響應
#[derive(Debug, Serialize)]
pub struct PlaceOrderResult {
    pub order_id: u64,          // 0 = 全部立即成交
    pub filled: u128,           // 立即成交量
    pub remaining: u128,        // 掛單剩餘量
    pub trades: Vec<Trade>,     // 成交記錄
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

    /// 用戶入金（從鏈上 deposit 事件同步）
    pub fn deposit(&mut self, user: &str, amount: u128) {
        *self.balances.entry(user.to_string()).or_insert(0) += amount;
    }

    /// 用戶提現（需 TEE 簽名後才能實際轉出）
    pub fn withdraw(&mut self, user: &str, amount: u128) -> bool {
        let bal = self.balances.entry(user.to_string()).or_insert(0);
        if *bal < amount { return false; }
        *bal -= amount;
        true
    }

    /// 下限價買單
    pub fn place_buy(&mut self, maker: &str, option: usize, price: u128, amount: u128) -> PlaceOrderResult {
        let total_cost = (price * amount) / 1_000_000_000_000_000_000u128;
        let bal = self.balances.entry(maker.to_string()).or_insert(0);
        if *bal < total_cost {
            return PlaceOrderResult { order_id: 0, filled: 0, remaining: amount, trades: vec![] };
        }
        *bal -= total_cost;  // 鎖定資金

        let mut remaining = amount;
        let mut trades = Vec::new();
        let mut filled = 0u128;

        // 撮合賣單（價格低→高）
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

                        // 賣方收到 ETH
                        *self.balances.entry(ask.maker.clone()).or_insert(0) += cost;
                        // 退買方差價
                        let refund = ((price - ask_price) * match_amt) / 1_000_000_000_000_000_000u128;
                        *self.balances.entry(maker.to_string()).or_insert(0) += refund;
                        // 股票轉移
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

        // 剩餘掛買單
        let order_id = if remaining > 0 {
            let id = self.next_order_id();
            let order = Order {
                id, maker: maker.to_string(), option_index: option,
                is_bid: true, price, amount: remaining, filled: 0,
                timestamp: Self::now_ms(),
            };
            let entry = book.bids.entry(price).or_default();
            // 買單按價格高→低，需要 reverse iteration。這裡用 reverse key 儲存
            // BTreeMap 默認升序。我們在查詢時 reverse iterate。
            entry.push(id);
            self.orders.insert(id, order);
            self.user_order_ids.entry(maker.to_string()).or_default().push(id);
            id
        } else {
            0
        };

        PlaceOrderResult { order_id, filled, remaining, trades }
    }

    /// 下限價賣單
    pub fn place_sell(&mut self, maker: &str, option: usize, price: u128, amount: u128) -> PlaceOrderResult {
        let pos = self.positions.entry(maker.to_string()).or_insert_with(|| vec![0; self.option_count]);
        if pos[option] < amount {
            return PlaceOrderResult { order_id: 0, filled: 0, remaining: amount, trades: vec![] };
        }
        pos[option] -= amount;  // 鎖定股票

        let mut remaining = amount;
        let mut trades = Vec::new();
        let mut filled = 0u128;

        // 撮合買單（價格高→低，reverse iterate BTreeMap）
        let book = &mut self.books[option];
        let bid_prices: Vec<u128> = book.bids.keys().copied().rev().collect(); // 高→低
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

                        // 賣方收到 ETH（按買價成交）
                        *self.balances.entry(maker.to_string()).or_insert(0) += revenue;
                        // 買方獲得股票
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

    /// 取消訂單
    pub fn cancel_order(&mut self, maker: &str, order_id: u64) -> Option<(u128, u128)> {
        let order = self.orders.get_mut(&order_id)?;
        if order.maker != maker { return None; }
        let remaining = order.amount - order.filled;
        if remaining == 0 { return None; }

        let book = &mut self.books[order.option_index];
        if order.is_bid {
            // 退還鎖定資金
            let refund = (order.price * remaining) / 1_000_000_000_000_000_000u128;
            *self.balances.entry(maker.to_string()).or_insert(0) += refund;
            // 從買單隊列移除
            if let Some(ids) = book.bids.get_mut(&order.price) {
                ids.retain(|&id| id != order_id);
                if ids.is_empty() { book.bids.remove(&order.price); }
            }
        } else {
            // 退還鎖定股票
            self.positions.entry(maker.to_string()).or_insert_with(|| vec![0; self.option_count])[order.option_index] += remaining;
            // 從賣單隊列移除
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

    /// 獲取訂單簿深度（用於前端展示）
    pub fn depth(&self, option: usize) -> (Vec<(u128, u128)>, Vec<(u128, u128)>) {
        let book = &self.books[option];
        let mut bids: Vec<(u128, u128)> = Vec::new();
        let mut asks: Vec<(u128, u128)> = Vec::new();

        // 買單：價格高→低
        for (&price, ids) in book.bids.iter().rev() {
            let total: u128 = ids.iter()
                .filter_map(|id| self.orders.get(id))
                .map(|o| o.amount - o.filled)
                .sum();
            if total > 0 { bids.push((price, total)); }
        }

        // 賣單：價格低→高
        for (&price, ids) in book.asks.iter() {
            let total: u128 = ids.iter()
                .filter_map(|id| self.orders.get(id))
                .map(|o| o.amount - o.filled)
                .sum();
            if total > 0 { asks.push((price, total)); }
        }

        (bids, asks)
    }

    /// 計算最終結算金額（勝出選項贏家每股 = 1 ETH）
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
