#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

@test "help command exits successfully" {
  run "$REPO_ROOT/wordpress-rclone-migrations.sh" help
  [ "$status" -eq 0 ]
}

@test "help output includes usage text" {
  run "$REPO_ROOT/wordpress-rclone-migrations.sh" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown action exits with non-zero status" {
  run "$REPO_ROOT/wordpress-rclone-migrations.sh" not-a-real-action
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown action"* ]]
}

@test "push without config exits with non-zero status" {
  run "$REPO_ROOT/wordpress-rclone-migrations.sh" push
  [ "$status" -ne 0 ]
  [[ "$output" == *"Config file required for push operation"* ]]
}

@test "pull without config exits with non-zero status" {
  run "$REPO_ROOT/wordpress-rclone-migrations.sh" pull
  [ "$status" -ne 0 ]
  [[ "$output" == *"Config file required for pull operation"* ]]
}
