#!/usr/bin/env bats
# Per-test tags: one fast, one slow, one untagged. Untagged is the interesting
# case — the fast tier is a tag filter, so fast ≠ total − slow.

# bats test_tags=fast
@test "alpha: tagged fast" { true; }

# bats test_tags=slow
@test "alpha: tagged slow" { true; }

@test "alpha: untagged" { true; }
