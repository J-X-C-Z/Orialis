//! Reproducible local parser microbenchmark, not a gateway or Python comparison.
use hermes_rust_core::provider_stream::StreamAssembler;
use serde_json::{Value, json};
use std::{hint::black_box, time::Instant};
fn usage() -> (f64, f64, i64) {
    unsafe {
        let mut r: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut r);
        (
            r.ru_utime.tv_sec as f64 + r.ru_utime.tv_usec as f64 / 1e6,
            r.ru_stime.tv_sec as f64 + r.ru_stime.tv_usec as f64 / 1e6,
            r.ru_maxrss,
        )
    }
}
fn bench(name: &str, input: &[u8], chunk: usize, iterations: usize, expected: usize) -> Value {
    let before = usage();
    let start = Instant::now();
    let mut samples = Vec::new();
    for _ in 0..iterations {
        let start = Instant::now();
        let mut p = StreamAssembler::default();
        for bytes in input.chunks(chunk) {
            black_box(p.push(black_box(bytes)).unwrap());
        }
        let out = p.finish().unwrap();
        assert_eq!(out["content"].as_str().unwrap().len(), expected);
        black_box(out);
        samples.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    let elapsed = start.elapsed().as_secs_f64();
    let after = usage();
    samples.sort_by(f64::total_cmp);
    json!({"case":name,"input_bytes":input.len(),"chunk_bytes":chunk,"iterations":iterations,"wall_seconds":elapsed,"user_cpu_seconds":after.0-before.0,"system_cpu_seconds":after.1-before.1,"max_rss_kib":after.2,"MiB_per_second":(input.len()*iterations) as f64/1048576.0/elapsed,"p50_ms":samples[iterations/2],"p95_ms":samples[((iterations as f64*0.95)as usize).min(iterations-1)],"raw_ms":samples})
}
fn main() {
    let mut cases = Vec::new();
    for n in [4096, 65536, 196608] {
        let data = format!(
            "data: {}\n\ndata: [DONE]\n\n",
            json!({"choices":[{"index":0,"delta":{"content":"x".repeat(n)},"finish_reason":"stop"}]})
        );
        cases.push(bench(
            &format!("long_event_{n}_one_byte"),
            data.as_bytes(),
            1,
            12,
            n,
        ));
    }
    let event = format!(
        "data: {}\n\n",
        json!({"choices":[{"index":0,"delta":{"content":"x"}}]})
    );
    for n in [100, 1000, 10000] {
        let data = event.repeat(n) + "data: [DONE]\n\n";
        cases.push(bench(
            &format!("many_events_{n}_one_chunk"),
            data.as_bytes(),
            data.len(),
            12,
            n,
        ));
        cases.push(bench(
            &format!("many_events_{n}_network4k"),
            data.as_bytes(),
            4096,
            12,
            n,
        ));
    }
    println!("{}",serde_json::to_string_pretty(&json!({"kind":"release SSE parser microbenchmark, not end-to-end","clock":"monotonic wall; getrusage process CPU and peak RSS","cases":cases})).unwrap());
}
