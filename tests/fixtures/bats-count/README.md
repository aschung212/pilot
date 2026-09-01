Fixture suite for the static test counter in `lib/doc-drift-check.py`.

These `.bats` files are **not** part of Pilot's suite: `run-tests.sh` and the
counter both glob `tests/*.bats`, which does not recurse into `fixtures/`.

They live as real files rather than heredocs inside `doc-drift-audit.bats`
because bats' preprocessor rewrites any line matching its `@test` pattern
**even inside a heredoc body** — a `cat <<'EOF' … @test "x" { } … EOF` writes
`bats_test_function --description x …` to disk, not `@test`. Generating a
fixture suite inline is therefore impossible; it writes mangled files, and the
stray `# bats file_tags=` lines leak into the enclosing file's tag state.

Known shape (assert against these numbers):

| file          | tests | carrying `fast` | pins                                    |
|---------------|-------|-----------------|-----------------------------------------|
| `alpha.bats`  | 3     | 1               | per-test tags; untagged ≠ fast          |
| `beta.bats`   | 2     | 2               | `file_tags` applies to every test       |
| `gamma.bats`  | 2     | 1               | comma lists; `test_tags` reset per test |
| **total**     | **7** | **4**           | 3 files                                 |

`alpha.bats` is the one that matters most: the fast tier is a *tag filter*, so
an untagged test runs in neither tier and `fast ≠ total − slow`.
