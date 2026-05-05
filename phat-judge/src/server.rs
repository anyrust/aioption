//! HTTP API Server — TEE 內部服務

use std::sync::Arc;
use axum::{
    Router, extract::{State, Path, Query},
    response::Json,
    routing::{get, post, delete},
};
use serde::{Deserialize, Serialize};
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct PlaceOrderRequest {
    pub maker: String,
    pub option_index: usize,
    pub is_bid: bool,
    pub price: u128,
    pub amount: u128,
}

#[derive(Debug, Deserialize)]
pub struct DepositRequest {
    pub user: String,
    pub amount: u128,
}

#[derive(Debug, Serialize)]
pub struct DepthResponse {
    pub bids: Vec<Level>,
    pub asks: Vec<Level>,
}

#[derive(Debug, Serialize)]
pub struct Level {
    pub price: u128,
    pub amount: u128,
}

pub async fn run(state: AppState, port: u16) {
    let shared = Arc::new(state);

    let app = Router::new()
        // 訂單簿
        .route("/book/{option}", get(get_depth))
        .route("/order", post(place_order))
        .route("/order/{id}", delete(cancel_order))
        // 資金
        .route("/deposit", post(handle_deposit))
        .route("/balance/{user}", get(get_balance))
        // 持倉
        .route("/position/{user}", get(get_position))
        // 健康檢查 + TEE 信息
        .route("/health", get(health))
        // 結算（僅在 RESOLVED 後調用）
        .route("/settle/{option}", post(settle))
        .with_state(shared);

    let addr = format!("0.0.0.0:{}", port);
    tracing::info!("HTTP server listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

/// GET /health
async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "tee": "intel-tdx",
        "attestable": true,
    }))
}

/// POST /order
async fn place_order(
    State(state): State<Arc<AppState>>,
    Json(req): Json<PlaceOrderRequest>,
) -> Json<serde_json::Value> {
    let mut engine = state.engine.write().unwrap();
    let result = if req.is_bid {
        engine.place_buy(&req.maker, req.option_index, req.price, req.amount)
    } else {
        engine.place_sell(&req.maker, req.option_index, req.price, req.amount)
    };

    Json(serde_json::json!({
        "order_id": result.order_id,
        "filled": result.filled,
        "remaining": result.remaining,
        "trades": result.trades.len(),
    }))
}

/// DELETE /order/:id
async fn cancel_order(
    State(state): State<Arc<AppState>>,
    Path(id): Path<u64>,
    Query(params): Query<HashMap<String, String>>,
) -> Json<serde_json::Value> {
    let maker = params.get("maker").cloned().unwrap_or_default();
    let mut engine = state.engine.write().unwrap();
    let result = engine.cancel_order(&maker, id);

    Json(serde_json::json!({
        "cancelled": result.is_some(),
        "refund": result.map(|(r, _)| r).unwrap_or(0),
    }))
}

/// GET /book/:option
async fn get_depth(
    State(state): State<Arc<AppState>>,
    Path(option): Path<usize>,
) -> Json<DepthResponse> {
    let engine = state.engine.read().unwrap();
    let (bids, asks) = engine.depth(option);

    Json(DepthResponse {
        bids: bids.into_iter().map(|(p, a)| Level { price: p, amount: a }).collect(),
        asks: asks.into_iter().map(|(p, a)| Level { price: p, amount: a }).collect(),
    })
}

/// POST /deposit
async fn handle_deposit(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DepositRequest>,
) -> Json<serde_json::Value> {
    let mut engine = state.engine.write().unwrap();
    engine.deposit(&req.user, req.amount);
    Json(serde_json::json!({"status": "ok"}))
}

/// GET /balance/:user
async fn get_balance(
    State(state): State<Arc<AppState>>,
    Path(user): Path<String>,
) -> Json<serde_json::Value> {
    let engine = state.engine.read().unwrap();
    let bal = engine.balances.get(&user).copied().unwrap_or(0);
    Json(serde_json::json!({"user": user, "balance": bal}))
}

/// GET /position/:user
async fn get_position(
    State(state): State<Arc<AppState>>,
    Path(user): Path<String>,
) -> Json<serde_json::Value> {
    let engine = state.engine.read().unwrap();
    let pos = engine.positions.get(&user).cloned().unwrap_or_default();
    Json(serde_json::json!({"user": user, "positions": pos}))
}

/// POST /settle/:winning_option
async fn settle(
    State(state): State<Arc<AppState>>,
    Path(winning): Path<usize>,
) -> Json<serde_json::Value> {
    let engine = state.engine.read().unwrap();
    let payouts = engine.calculate_settlement(winning);

    // TODO: 用 TEE 私鑰簽名結算批次，提交到以太坊 BetContract.settle()
    let total: u128 = payouts.iter().map(|(_, a)| a).sum();

    Json(serde_json::json!({
        "winning_option": winning,
        "recipients": payouts.len(),
        "total_payout": total,
        "payouts": payouts,
    }))
}

use std::collections::HashMap;
