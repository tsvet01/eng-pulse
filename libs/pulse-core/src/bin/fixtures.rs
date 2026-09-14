//! Writes docs/contracts/*.json. CI regenerates and fails on drift.
fn main() {
    let out = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "docs/contracts".into());
    std::fs::create_dir_all(&out).expect("create contracts dir");
    for (name, value) in pulse_core::fixtures() {
        let path = format!("{out}/{name}.json");
        let pretty = serde_json::to_string_pretty(&value).unwrap() + "\n";
        std::fs::write(&path, pretty).expect("write fixture");
        println!("wrote {path}");
    }
}
