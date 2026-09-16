#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    pulse_api::run().await
}
