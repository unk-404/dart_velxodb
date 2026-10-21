use std::io::Write;
use std::time::Instant;

const TOTAL: usize = 100_000;
const READS: usize = 20_000;
const REOPEN_READS: usize = 1_000;
const BATCH: usize = 500;
const RANGE_START: usize = 10_000;
const RANGE_END: usize = 20_000;

fn key(index: usize) -> String {
    format!("doc-{:09}", index)
}

fn emit(engine: &str, phase: &str, micros: u128, entries: usize) {
    println!(
        "{{\"engine\":\"{}\",\"phase\":\"{}\",\"ms\":{:.3},\"entries\":{},\"bytes\":130}}",
        engine, phase, micros as f64 / 1000.0, entries
    );
    let _ = std::io::stdout().flush();
}

fn emit_disk(engine: &str, bytes: u64) {
    println!(
        "{{\"engine\":\"{}\",\"phase\":\"disk\",\"ms\":0.0,\"entries\":0,\"bytes\":{}}}",
        engine, bytes
    );
    let _ = std::io::stdout().flush();
}

fn directory_bytes(path: &std::path::Path) -> u64 {
    let mut total = 0;
    if let Ok(entries) = std::fs::read_dir(path) {
        for entry in entries.flatten() {
            let path = entry.path();
            if let Ok(metadata) = entry.metadata() {
                if metadata.is_dir() {
                    total += directory_bytes(&path);
                } else {
                    total += metadata.len();
                }
            }
        }
    }
    total
}

fn main() {
    let dir = std::env::current_dir().unwrap().join("sled_db");
    let _ = std::fs::remove_dir_all(&dir);

    let mut seed: u64 = 0x9E37_79B9;
    let mut next = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed >> 1) as usize
    };

    let document = vec![b'x'; 130];
    let db = sled::open(&dir).unwrap();

    let start = Instant::now();
    let mut batch = sled::Batch::default();
    let mut pending = 0;
    for index in 0..TOTAL {
        batch.insert(key(index).as_bytes(), document.clone());
        pending += 1;
        if pending == BATCH {
            db.apply_batch(batch).unwrap();
            batch = sled::Batch::default();
            pending = 0;
        }
    }
    if pending > 0 {
        db.apply_batch(batch).unwrap();
    }
    emit("sled", "import", start.elapsed().as_micros(), TOTAL);

    let start = Instant::now();
    let mut hits = 0;
    for _ in 0..READS {
        if db.get(key(next() % TOTAL).as_bytes()).unwrap().is_some() {
            hits += 1;
        }
    }
    emit("sled", "get", start.elapsed().as_micros(), READS);
    eprintln!("  sled hits={}", hits);

    let start = Instant::now();
    let mut count = 0;
    for item in db.range(key(RANGE_START).as_bytes()..key(RANGE_END).as_bytes()) {
        if item.is_ok() {
            count += 1;
        }
    }
    emit("sled", "range", start.elapsed().as_micros(), count);
    eprintln!("  sled range={}", count);

    let start = Instant::now();
    drop(db);
    let db = sled::open(&dir).unwrap();
    for _ in 0..REOPEN_READS {
        let _ = db.get(key(next() % TOTAL).as_bytes());
    }
    emit("sled", "reopen", start.elapsed().as_micros(), REOPEN_READS);

    drop(db);
    emit_disk("sled", directory_bytes(&dir));
    std::fs::remove_dir_all(&dir).ok();
}
