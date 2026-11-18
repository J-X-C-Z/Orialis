//! Exact eager-scanner parity tests for necessary-fragment lazy compilation.
#[path = "support/memory_safety_differential.rs"]
mod differential;
#[path = "fixtures/memory_safety_eager_reference.rs"]
mod eager;
#[path = "../src/memory_safety.rs"]
mod lazy;
