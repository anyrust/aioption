//! AI Judge — Calls OpenRouter API

use serde::{Deserialize, Serialize};

const SYSTEM_PROMPT: &str = r#"You are an impartial AI judge for a decentralized prediction market.
Your task is to evaluate a bet/question and determine which option is the correct outcome.

Rules:
1. Base your judgment ONLY on verifiable facts and the provided context.
2. If the question is ambiguous, interpret it as a reasonable person would.
3. You MUST respond with exactly the option INDEX (0-based integer) that won.
4. Example: for options ["YES","NO"], respond "0" for YES or "1" for NO.
5. For ["Team A wins","Team B wins","Draw"], respond "0","1",or "2".
6. Do NOT provide any explanation, reasoning, or additional text.

Your response will be cryptographically signed inside a TEE (Trusted Execution Environment)
to prove it came from an unmodified AI judge."#;

#[derive(Debug, Serialize)]
struct ChatRequest {
    model: String,
    messages: Vec<Message>,
    max_tokens: u32,
    temperature: f64,
}

#[derive(Debug, Serialize)]
struct Message {
    role: String,
    content: String,
}

#[derive(Debug, Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: ChoiceMessage,
}

#[derive(Debug, Deserialize)]
struct ChoiceMessage {
    content: String,
}

pub struct AiJudge {
    api_key: String,
    model: String,
    client: reqwest::blocking::Client,
}

impl AiJudge {
    pub fn new(api_key: &str) -> Self {
        Self {
            api_key: api_key.to_string(),
            model: "anthropic/claude-opus-4-6".to_string(),
            client: reqwest::blocking::Client::new(),
        }
    }

    /// Judge the outcome of a bet
    /// Returns: option index (0-based)
    pub fn judge(&self, question: &str, options: &[String]) -> Option<usize> {
        let options_text: Vec<String> = options.iter()
            .enumerate()
            .map(|(i, name)| format!("[{}] {}", i, name))
            .collect();
        let user_message = format!(
            "Question: {}\n\nOptions:\n{}\n\nWhich option index is the correct outcome?",
            question,
            options_text.join("\n")
        );

        log::info!("Judging: {} ({} options)", question, options.len());

        for attempt in 0..3 {
            match self.call_api(&user_message) {
                Ok(response) => {
                    // Parse response as a number
                    let trimmed = response.trim();
                    if let Ok(idx) = trimmed.parse::<usize>() {
                        if idx < options.len() {
                            log::info!("AI result: option {} ({})", idx, options[idx]);
                            return Some(idx);
                        }
                    }
                    log::warn!("Unexpected AI response: {}", trimmed);
                    // Try to find a digit in the response
                    if let Some(first_num) = trimmed.chars().find(|c| c.is_ascii_digit()) {
                        if let Some(idx) = first_num.to_digit(10) {
                            let idx = idx as usize;
                            if idx < options.len() {
                                return Some(idx);
                            }
                        }
                    }
                }
                Err(e) => {
                    log::error!("API error (attempt {}): {}", attempt + 1, e);
                    if attempt < 2 {
                        std::thread::sleep(std::time::Duration::from_secs(2_u64.pow(attempt)));
                    }
                }
            }
        }
        None // Unable to determine
    }

    fn call_api(&self, user_message: &str) -> Result<String, Box<dyn std::error::Error>> {
        let req = ChatRequest {
            model: self.model.clone(),
            messages: vec![
                Message { role: "system".into(), content: SYSTEM_PROMPT.into() },
                Message { role: "user".into(), content: user_message.into() },
            ],
            max_tokens: 10,
            temperature: 0.0,
        };

        let resp: ChatResponse = self.client
            .post("https://openrouter.ai/api/v1/chat/completions")
            .header("Authorization", format!("Bearer {}", self.api_key))
            .header("HTTP-Referer", "https://github.com/aioption")
            .header("X-Title", "AI Option Judge")
            .json(&req)
            .send()?
            .json()?;

        Ok(resp.choices[0].message.content.clone())
    }
}
