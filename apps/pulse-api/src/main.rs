#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    if args.next().as_deref() == Some("pilot-push-test") {
        return pulse_api::notify::probe::run(&args.collect::<Vec<_>>())
            .await
            .map_err(Into::into);
    }
    pulse_api::run().await
}
