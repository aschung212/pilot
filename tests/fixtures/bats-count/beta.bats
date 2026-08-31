#!/usr/bin/env bats
# file_tags applies to every test in the file, and unions with a test's own.
# bats file_tags=fast

@test "beta: inherits the file tag" { true; }

# bats test_tags=slow
@test "beta: file tag unions with its own tag" { true; }
