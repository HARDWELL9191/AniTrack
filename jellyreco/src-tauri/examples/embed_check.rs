//! Developer check: embeds texts with the app's AI engine and prints tokens + vectors as JSON,
//! so they can be compared with the reference Python pipeline.
//! cargo run --example embed_check -- <resources dir> <data dir> <texts.json>

use jellyreco_lib::ai::{tokenizer::WordPiece, Engine, Paths, SEQ_LEN};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (res, data, texts) = (&args[1], &args[2], &args[3]);
    let texts: Vec<String> = serde_json::from_str(&std::fs::read_to_string(texts).unwrap()).unwrap();
    let tok = WordPiece::from_vocab(&std::fs::read_to_string(format!("{res}/vocab.txt")).unwrap()).unwrap();
    let engine = Engine::new(Paths { resources: res.into(), data: data.into() });
    let items: Vec<(i64, String)> = texts.iter().enumerate().map(|(i, t)| (i as i64, t.clone())).collect();
    let vectors = engine.vectors(&items).expect("embedding failed");
    let mut out = serde_json::Map::new();
    for (i, t) in texts.iter().enumerate() {
        let ids: Vec<i64> = tok.encode(t, SEQ_LEN).input_ids.into_iter().take(40).collect();
        out.insert(i.to_string(), serde_json::json!({ "ids": ids, "full": vectors[&(i as i64)] }));
    }
    let status = engine.status();
    println!("{}", serde_json::json!({ "backend": status.backend, "detail": status.detail, "out": out }));
    // Second call: everything comes from the saved vector file (no model run).
    let again = Engine::new(Paths { resources: res.into(), data: data.into() });
    let cached = again.cached(&(0..texts.len() as i64).collect::<Vec<_>>());
    eprintln!("cached after restart: {}", cached.len());
}
