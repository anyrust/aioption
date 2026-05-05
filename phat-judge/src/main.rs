//! AI Option Judge — High-Performance TEE Order Book + AI Judge
//!
//! Deployed on Phala Cloud (dstack CVM), running inside Intel TDX TEE
//!
//! Modules:
//!   orderbook — BTreeMap matching engine
//!   judge     — OpenRouter AI API
//!   server    — HTTP API (place order / order book depth / cancel)
//!   settle    — On-chain settlement integration

pub mod orderbook;
pub mod judge;
pub mod blockchain;
pub mod server;

use std::sync::{Arc, RwLock};
use crate::orderbook::OrderBookEngine;

/// Global application state (shared within TEE)
pub struct AppState {
    pub engine: Arc<RwLock<OrderBookEngine>>,
    pub rpc_url: String,
    pub bet_contract: String,
    pub provider_registry: String,
    pub eth_private_key: String,
    pub openrouter_key: String,
}

impl AppState {
    pub fn new(
        option_count: usize,
        rpc_url: &str,
        bet_contract: &str,
        provider_registry: &str,
        eth_private_key: &str,
        openrouter_key: &str,
    ) -> Self {
        Self {
            engine: Arc::new(RwLock::new(OrderBookEngine::new(option_count))),
            rpc_url: rpc_url.to_string(),
            bet_contract: bet_contract.to_string(),
            provider_registry: provider_registry.to_string(),
            eth_private_key: eth_private_key.to_string(),
            openrouter_key: openrouter_key.to_string(),
        }
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter("info")
        .init();

    let option_count: usize = std::env::var("OPTION_COUNT")
        .unwrap_or("2".into())
        .parse()
        .unwrap_or(2);
    let rpc_url = std::env::var("RPC_URL")
        .unwrap_or("https://ethereum-sepolia.publicnode.com".into());
    let bet_contract = std::env::var("BET_CONTRACT_ADDRESS")
        .expect("BET_CONTRACT_ADDRESS required");
    let provider_registry = std::env::var("PROVIDER_REGISTRY_ADDRESS")
        .expect("PROVIDER_REGISTRY_ADDRESS required");
    let eth_private_key = std::env::var("ETH_PRIVATE_KEY")
        .expect("ETH_PRIVATE_KEY required");
    let openrouter_key = std::env::var("OPENROUTER_API_KEY")
        .expect("OPENROUTER_API_KEY required");
    let port: u16 = std::env::var("PORT")
        .unwrap_or("8080".into())
        .parse()
        .unwrap_or(8080);

    let state = AppState::new(
        option_count, &rpc_url, &bet_contract,
        &provider_registry, &eth_private_key, &openrouter_key,
    );

    tracing::info!("AI Option Judge starting on port {}", port);
    tracing::info!("BetContract: {}", bet_contract);
    tracing::info!("Options: {}", option_count);

    server::run(state, port).await;
}
