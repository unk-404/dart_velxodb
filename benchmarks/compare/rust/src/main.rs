use std::io::Write;
use std::time::Instant;

const TOTAL: usize = 100_000;
const READS: usize = 20_000;
const REOPEN_READS: usize = 1_000;
const WARMUP_READS: usize = 1_000;
const BATCH: usize = 500;
const RANGE_START: usize = 10_000;
const RANGE_END: usize = 20_000;
/// Same seed and same xorshift32 as `dart/bin/run.dart`, so every engine reads
/// the identical key sequence.
const SEED: u32 = 0x9E37_79B9;

fn key(index: usize) -> String {
    format!("doc-{:09}", index)
}

fn emit(engine: &str, phase: &str, micros: u128, entries: usize) {
    println!(
        "{{\"engine\":\"{}\",\"phase\":\"{}\",\"ms\":{:.3},\"entries\":{},\"bytes\":0}}",
        engine,
        phase,
        micros as f64 / 1000.0,
        entries
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

/// The payload velxodb writes, dumped by the Dart harness.
///
/// Falls back to a 130-byte filler only when the fixture is missing, so a
/// standalone `cargo run` still works.
fn payload() -> Vec<u8> {
    let path = std::env::var("VELXO_FIXTURE")
        .unwrap_or_else(|_| "../dart/.tmp/fixture130.bin".to_string());
    match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(_) => {
            eprintln!("warning: fixture {path} missing, using 130 filler bytes");
            vec![b'x'; 130]
        }
    }
}

/// Shared read sequence: reopen reads, warm-up reads, then timed reads.
fn read_sequence() -> Vec<usize> {
    let mut state = SEED;
    let mut out = Vec::with_capacity(REOPEN_READS + WARMUP_READS + READS);
    for _ in 0..(REOPEN_READS + WARMUP_READS + READS) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        out.push((state & 0x7fff_ffff) as usize % TOTAL);
    }
    out
}

fn main() {
    let dir = std::env::current_dir().unwrap().join("sled_db");
    let _ = std::fs::remove_dir_all(&dir);

    let document = payload();
    let sequence = read_sequence();
    let mut cursor = 0usize;

    // The first open is on an empty database and is not a measured phase.
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

    // Persist before every read/query phase, matching velxodb's flush+close.
    db.flush().unwrap();
    drop(db);
    emit_disk("sled", directory_bytes(&dir));

    // Reopen: measure the open call alone, then the reads.
    let start = Instant::now();
    let db = sled::open(&dir).unwrap();
    emit("sled", "open", start.elapsed().as_micros(), 0);

    let start = Instant::now();
    for _ in 0..REOPEN_READS {
        let _ = db.get(key(sequence[cursor]).as_bytes());
        cursor += 1;
    }
    emit("sled", "reopen", start.elapsed().as_micros(), REOPEN_READS);

    for _ in 0..WARMUP_READS {
        let _ = db.get(key(sequence[cursor]).as_bytes());
        cursor += 1;
    }

    let start = Instant::now();
    let mut hits = 0;
    for _ in 0..READS {
        if db.get(key(sequence[cursor]).as_bytes()).unwrap().is_some() {
            hits += 1;
        }
        cursor += 1;
    }
    if hits != READS {
        panic!("sled hits {} != {}", hits, READS);
    }
    emit("sled", "get", start.elapsed().as_micros(), READS);

    let start = Instant::now();
    let mut count = 0;
    for item in db.range(key(RANGE_START).as_bytes()..key(RANGE_END).as_bytes()) {
        if item.is_ok() {
            count += 1;
        }
    }
    if count != RANGE_END - RANGE_START {
        panic!("sled range {} != {}", count, RANGE_END - RANGE_START);
    }
    emit("sled", "range", start.elapsed().as_micros(), count);

    drop(db);
    std::fs::remove_dir_all(&dir).ok();
}
