mod common;
use common::Pt;

const DONE: &[&str] = &[
    "--json",
    "--idempotency-key",
    "batch1",
    "done",
    "alpha",
    "bravo",
];

fn setup() -> Pt {
    let pt = Pt::new();
    pt.ok(&["add", "--raw", "alpha"]);
    pt.ok(&["add", "--raw", "bravo"]);
    pt
}

fn replayed(pt: &Pt) {
    let results: serde_json::Value = serde_json::from_str(&pt.ok(DONE)).unwrap();
    assert_eq!(results[0]["outcome"], "replayed");
    assert_eq!(results[1]["outcome"], "replayed");
    assert_eq!(results[0]["pt_id"], "PT-1");
    assert_eq!(results[1]["pt_id"], "PT-2");
}

#[test]
fn retry_after_new_same_titles_does_not_close_new_tasks() {
    let pt = setup();
    pt.ok(DONE);
    pt.ok(&["add", "--raw", "alpha"]);
    pt.ok(&["add", "--raw", "bravo"]);
    replayed(&pt);
    assert_eq!(pt.json(&["show", "PT-3"])["status"], "todo");
    assert_eq!(pt.json(&["show", "PT-4"])["status"], "todo");
}

#[test]
fn immediate_retry_replays() {
    let pt = setup();
    pt.ok(DONE);
    replayed(&pt);
}

#[test]
fn mismatched_arguments_and_actor_are_rejected() {
    let pt = setup();
    pt.ok(DONE);
    for args in [
        vec!["--idempotency-key", "batch1", "done", "bravo", "alpha"],
        vec![
            "--idempotency-key",
            "batch1",
            "done",
            "alpha",
            "bravo",
            "--note",
            "changed",
        ],
    ] {
        let out = pt.run(&args);
        assert!(!out.status.success());
        assert!(String::from_utf8_lossy(&out.stderr).contains("idempotency"));
    }
    assert!(!pt.run_as("other", DONE).status.success());
}

#[test]
fn missing_target_stays_missing_on_retry() {
    let pt = Pt::new();
    pt.ok(&["add", "--raw", "alpha"]);
    let first = pt.run(DONE);
    assert!(!first.status.success());
    let first: serde_json::Value = serde_json::from_slice(&first.stdout).unwrap();
    assert_eq!(first[0]["outcome"], "completed");
    assert_eq!(first[1]["outcome"], "error");
    pt.ok(&["add", "--raw", "bravo"]);
    let retry = pt.run(DONE);
    assert!(!retry.status.success());
    let retry: serde_json::Value = serde_json::from_slice(&retry.stdout).unwrap();
    assert_eq!(retry[0]["outcome"], "replayed");
    assert_eq!(retry[1], first[1]);
    assert_eq!(pt.json(&["show", "PT-2"])["status"], "todo");
}

#[test]
fn blocked_target_retries_the_original_uuid() {
    let pt = setup();
    pt.ok(&["add", "--raw", "prerequisite"]);
    pt.ok(&["depend", "PT-2", "--on", "PT-3"]);
    let first = pt.run(DONE);
    assert!(!first.status.success());
    let first: serde_json::Value = serde_json::from_slice(&first.stdout).unwrap();
    assert_eq!(first[0]["outcome"], "completed");
    assert_eq!(first[1]["outcome"], "error");
    pt.ok(&["done", "PT-3"]);
    pt.ok(&["add", "--raw", "bravo"]);
    let retry: serde_json::Value = serde_json::from_str(&pt.ok(DONE)).unwrap();
    assert_eq!(retry[0]["outcome"], "replayed");
    assert_eq!(retry[1]["pt_id"], "PT-2");
    assert_eq!(retry[1]["outcome"], "completed");
    assert_eq!(pt.json(&["show", "PT-4"])["status"], "todo");
}
