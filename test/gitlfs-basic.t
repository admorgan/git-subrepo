#!/usr/bin/env bash

set -e

source test/setup

use Test::More

# Check if git-lfs is available
if ! command -v git-lfs >/dev/null 2>&1; then
  plan skip_all "git-lfs is not installed"
fi

# Start lfs-test-server for this test
start-lfs-test-server

if [ -z "${LFS_URL:-}" ]; then
  plan skip_all "lfs-test-server is not available"
fi

note "Test basic git-subrepo operations with Git LFS files"

clone-foo-and-bar

# Set up LFS in the bar repo (subrepo)
(
  cd "$OWNER/bar"
  setup-lfs-repo "."
  git config lfs.url "$LFS_URL"
  add-lfs-file "large.bin" "Large binary content for testing"
  git push
) &> /dev/null || die "Failed to setup LFS in bar repo"

# Set up LFS in the foo repo (main repo)
(
  cd "$OWNER/foo"
  git lfs install
  git config lfs.url "$LFS_URL"
  git config lfs.locksverify false
) &> /dev/null || die "Failed to setup LFS in foo repo"

# Test: Clone subrepo with LFS files
clone_output=$(
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar"
)

is "$clone_output" \
  "Subrepo '$UPSTREAM/bar' (master) cloned into 'bar'." \
  'Subrepo clone with LFS files succeeds'

# Ensure LFS files are present
(
  cd "$OWNER/foo/bar"
  git lfs pull 2>/dev/null || true
  git lfs checkout 2>/dev/null || true
) &> /dev/null || die

# Verify LFS files were cloned
test-exists \
  "$OWNER/foo/bar/large.bin" \
  "$OWNER/foo/bar/.gitattributes"

# Check that LFS file has actual content (not a pointer)
test-lfs-file-content "$OWNER/foo/bar/large.bin" "Large binary content for testing"

# Test: Add new LFS file to subrepo and pull
(
  cd "$OWNER/bar"
  add-lfs-file "another.lfs" "Another large file for pull test"
  git push
) &> /dev/null || die "Failed to add new LFS file to bar repo"

pull_output=$(
  cd "$OWNER/foo"
  git subrepo pull bar
)

# Ensure new LFS files are present
(
  cd "$OWNER/foo/bar"
  git lfs pull 2>/dev/null || true
  git lfs checkout 2>/dev/null || true
) &> /dev/null || die

is "$pull_output" \
  "Subrepo 'bar' pulled from '$UPSTREAM/bar' (master)." \
  'Subrepo pull with new LFS files succeeds'

test-exists "$OWNER/foo/bar/another.lfs"
test-lfs-file-content "$OWNER/foo/bar/another.lfs" "Another large file for pull test"

# Test: Modify LFS file and push
(
  cd "$OWNER/foo"
  add-lfs-file "bar/modified.bin" "Modified LFS file from main repo"
) &> /dev/null || die "Failed to add modified LFS file"

push_output=$(
  cd "$OWNER/foo"
  git subrepo push bar
)

is "$push_output" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  'Subrepo push with LFS files succeeds'

# Verify push worked
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull pushed changes"

test-exists "$OWNER/bar/modified.bin"
test-lfs-file-content "$OWNER/bar/modified.bin" "Modified LFS file from main repo"

# Test: LFS files work with branch command
(
  cd "$OWNER/foo"
  add-lfs-file "bar/branch-test.bin" "Branch test LFS content"
) &> /dev/null || die "Failed to add LFS file for branch test"

# Fetch to sync subrepo state before branch operation
(
  cd "$OWNER/foo"
  git subrepo fetch bar
) &> /dev/null || die

branch_output=$(
  cd "$OWNER/foo"
  git subrepo branch bar
)

is "$branch_output" \
  "Created branch 'subrepo/bar' and worktree '.git/tmp/subrepo/bar'." \
  'Subrepo branch works with LFS files'

# Verify branch worktree has LFS files
test-exists "$OWNER/foo/.git/tmp/subrepo/bar/branch-test.bin"

# Clean up branch
(
  cd "$OWNER/foo"
  git subrepo clean bar
) &> /dev/null || die "Failed to clean subrepo branch"

# Test: Squash push with LFS files
(
  cd "$OWNER/foo"
  add-lfs-file "bar/squash1.lfs" "First squash LFS file"
  add-lfs-file "bar/squash2.lfs" "Second squash LFS file"
) &> /dev/null || die "Failed to add LFS files for squash test"

squash_output=$(
  cd "$OWNER/foo"
  git subrepo push bar --squash
)

is "$squash_output" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  'Subrepo push --squash works with LFS files'

# Verify squashed LFS files
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull squashed changes"

test-exists \
  "$OWNER/bar/squash1.lfs" \
  "$OWNER/bar/squash2.lfs"

test-lfs-file-content "$OWNER/bar/squash1.lfs" "First squash LFS file"
test-lfs-file-content "$OWNER/bar/squash2.lfs" "Second squash LFS file"

# Test: Status command works with LFS subrepo
status_output=$(
  cd "$OWNER/foo"
  git subrepo status bar
)

like "$status_output" \
  "Git subrepo 'bar':" \
  'Status command works with LFS subrepo'

done_testing

teardown
