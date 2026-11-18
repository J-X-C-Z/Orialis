#!/usr/bin/env bash
# Run only explicitly supported real-Server fixtures; never retry the IPC-denied tests.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export CARGO_HOME="$ROOT/.toolchain/cargo" RUSTUP_HOME="$ROOT/.toolchain/rustup"
export PATH="$CARGO_HOME/bin:$PATH"
export ORIALIS_REAL_SERVER_BIN="${ORIALIS_REAL_SERVER_BIN:-$ROOT/orialis/target/release/orialis-server}"
export ORIALIS_TEST_SERVER_BINARY="$ORIALIS_REAL_SERVER_BIN"
OUT="${OUT_DIR:-$ROOT/hermes-rust-core/results/final-validation/real-modules}"
mkdir -p "$OUT"
MANIFEST="$ROOT/hermes-rust-core/Cargo.toml"
run(){ name="$1";shift; "$@" > "$OUT/$name.log" 2>&1; result=$?; echo "$name:$result" | tee -a "$OUT/status.txt"; if [ "$result" -ne 0 ]; then tail -40 "$OUT/$name.log"; return "$result"; fi; }
: > "$OUT/status.txt"
failed=0
run domain cargo test --offline --manifest-path "$MANIFEST" --locked --lib real_server_all_39_tools_crud_news_owner_scope_and_versions -- --ignored || failed=1
run memory cargo test --offline --manifest-path "$MANIFEST" --locked --test memory_video actual_server_persists_video_analysis_without_chat_history -- --ignored || failed=1
run attachments cargo test --offline --manifest-path "$MANIFEST" --locked --test attachments_transport real_orialis_server_upload_download_idempotency_and_owner_auth -- --ignored || failed=1
run updates cargo test --offline --manifest-path "$MANIFEST" --locked --test conversation_updates actual_orialis_title_naming_and_racing_manual_rename_are_cas_safe -- --ignored || failed=1
run core cargo test --offline --manifest-path "$MANIFEST" --locked --test full_core_contract real_server_provider_domain_memory_attachment_restart -- --ignored || failed=1
run interactions cargo test --offline --manifest-path "$MANIFEST" --locked --test interactions_transport actual_server_mobile_clarify_approve_deny_and_expired_cleanup -- --ignored || failed=1
run outputs cargo test --offline --manifest-path "$MANIFEST" --locked --test output_files_transport real_orialis_artifact_snapshot_replay_and_download -- --ignored || failed=1
run deliveries python "$ROOT/hermes-rust-core/tests/delivery_server_contract.py" --server-binary "$ORIALIS_REAL_SERVER_BIN" --out "$OUT/deliveries.json" || failed=1
run commands python "$ROOT/hermes-rust-core/tests/session_commands_server.py" --server-binary "$ORIALIS_REAL_SERVER_BIN" --out "$OUT/commands.json" || failed=1
run events python "$ROOT/hermes-rust-core/tests/gateway_events_contract.py" --orialis "$ROOT/orialis" --server-binary "$ORIALIS_REAL_SERVER_BIN" --out "$OUT/events.json" || failed=1
exit "$failed"
