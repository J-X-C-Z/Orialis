use hermes_rust_core::{screen_memory, wire};
use serde_json::{Value, json};
use std::{hint::black_box, time::Instant};
fn measure(mut f: impl FnMut(), n: usize) -> Value {
    for _ in 0..100 {
        f();
    }
    let mut samples = Vec::with_capacity(n);
    for _ in 0..n {
        let t = Instant::now();
        f();
        samples.push(t.elapsed().as_nanos() as u64);
    }
    samples.sort_unstable();
    json!({"iterations":n,"mean_ns":samples.iter().sum::<u64>() as f64/n as f64,"median_ns":samples[n/2],"p95_ns":samples[n*95/100]})
}
fn main() {
    let a: Vec<_> = std::env::args().collect();
    let corpus: Value = serde_json::from_str(&std::fs::read_to_string(&a[1]).unwrap()).unwrap();
    let n = a.get(2).map(|s| s.parse().unwrap()).unwrap_or(20000);
    let mut out = json!({"implementation":"orialis-rust-subset","scope":"In-process supported-frame validation and serialization only; not full gateway performance","workloads":{}});
    for name in [
        "message_send",
        "message_reply",
        "memory_analyze",
        "memory_result",
    ] {
        let frame = &corpus[name];
        let raw = wire::encode(frame).unwrap();
        assert_eq!(wire::parse(&raw).unwrap(), *frame);
        out["workloads"][format!("{name}_parse")] = measure(
            || {
                black_box(wire::parse(black_box(&raw)).unwrap());
            },
            n,
        );
        out["workloads"][format!("{name}_encode")] = measure(
            || {
                black_box(wire::encode(black_box(frame)).unwrap());
            },
            n,
        );
    }
    let raw = corpus["structured_memory"].as_str().unwrap();
    out["workloads"]["structured_memory_parse"] = measure(
        || {
            black_box(screen_memory::structured_result(black_box(raw)).unwrap());
        },
        n,
    );
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}
