load test_helper

@test "helper sets an isolated root" {
  [[ "$VPS_APPS_ROOT" == "$BATS_TEST_TMPDIR"* ]]
}
