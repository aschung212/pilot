#!/usr/bin/env bats
# A comma-separated tag list, then an untagged test that must NOT inherit it:
# bats resets test_tags after every @test.

# bats test_tags=fast, integration
@test "gamma: comma-separated tag list" { true; }

@test "gamma: must not inherit the previous test's tags" { true; }
