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

note "Test git-subrepo with Git LFS support"

# Verify git-lfs version
note "Using git-lfs version: $(git lfs version 2>/dev/null | head -n1 || echo 'unknown')"

clone-foo-and-bar

# Set up LFS in the bar repo (subrepo)
(
  cd "$OWNER/bar"
  setup-lfs-repo "."
  git config lfs.url "$LFS_URL"
  add-lfs-file "binary.bin" "This is LFS binary content"
  add-lfs-file "large.large" "Large file for LFS tracking"
  add-new-files "regular.txt"
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
{
  clone_output=$(
    cd "$OWNER/foo"
    git subrepo clone "$UPSTREAM/bar"
  )

  is "$clone_output" \
    "Subrepo '$UPSTREAM/bar' (master) cloned into 'bar'." \
    'subrepo clone with LFS files succeeds'

  # Ensure LFS files are present
  (
    cd "$OWNER/foo/bar"
    git lfs pull 2>/dev/null || true
    git lfs checkout 2>/dev/null || true
  ) &> /dev/null || die
}

# Verify LFS files were cloned correctly
{
  test-exists \
    "$OWNER/foo/bar/binary.bin" \
    "$OWNER/foo/bar/large.large" \
    "$OWNER/foo/bar/regular.txt" \
    "$OWNER/foo/bar/.gitattributes"

  test-lfs-file-content "$OWNER/foo/bar/binary.bin" "This is LFS binary content"
  test-lfs-file-content "$OWNER/foo/bar/large.large" "Large file for LFS tracking"

  # Verify .gitattributes was cloned
  like "$(cat "$OWNER/foo/bar/.gitattributes")" \
    "\*\.bin.*filter=lfs" \
    'LFS tracking configuration cloned correctly'
}

# Test: Pull subrepo with new LFS files
(
  cd "$OWNER/bar"
  add-lfs-file "new.bin" "New LFS file content"
  git push
) &> /dev/null || die "Failed to add new LFS file to bar repo"

{
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
    'subrepo pull with new LFS files succeeds'

  test-exists "$OWNER/foo/bar/new.bin"
  test-lfs-file-content "$OWNER/foo/bar/new.bin" "New LFS file content"
}

# Test: Push changes with LFS files to subrepo
(
  cd "$OWNER/foo"
  echo "Modified LFS content" > bar/binary.bin
  git add bar/binary.bin
  git commit -m "Modify existing LFS file"
  add-lfs-file "bar/from-main.bin" "LFS file from main repo"
) &> /dev/null || die "Failed to modify LFS files in foo repo"

{
  push_output=$(
    cd "$OWNER/foo"
    git subrepo push bar
  )

  is "$push_output" \
    "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
    'subrepo push with LFS files succeeds'
}

# Verify changes were pushed correctly
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull changes in bar repo"

{
  test-exists \
    "$OWNER/bar/binary.bin" \
    "$OWNER/bar/from-main.bin"

  test-lfs-file-content "$OWNER/bar/binary.bin" "Modified LFS content"
  test-lfs-file-content "$OWNER/bar/from-main.bin" "LFS file from main repo"
}

# Test: LFS files work with branch command
(
  cd "$OWNER/foo"
  add-lfs-file "bar/branch-test.bin" "Branch test content"
) &> /dev/null || die "Failed to add LFS file for branch test"

# Fetch to sync subrepo state before branch operation
(
  cd "$OWNER/foo"
  git subrepo fetch bar
) &> /dev/null || die

{
  branch_output=$(
    cd "$OWNER/foo"
    git subrepo branch bar
  )

  is "$branch_output" \
    "Created branch 'subrepo/bar' and worktree '.git/tmp/subrepo/bar'." \
    'subrepo branch command works with LFS files'

  # Verify LFS files exist in the branch worktree
  test-exists "$OWNER/foo/.git/tmp/subrepo/bar/branch-test.bin"
}

# Clean up branch
(
  cd "$OWNER/foo"
  git subrepo clean bar
) &> /dev/null || die "Failed to clean subrepo branch"

# Test: Squash push with LFS files
(
  cd "$OWNER/foo"
  add-lfs-file "bar/squash1.bin" "First squash file"
  add-lfs-file "bar/squash2.bin" "Second squash file"
) &> /dev/null || die "Failed to add LFS files for squash test"

{
  squash_output=$(
    cd "$OWNER/foo"
    git subrepo push bar --squash
  )

  is "$squash_output" \
    "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
    'subrepo push --squash works with LFS files'
}

# Verify squashed LFS files
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull squashed changes in bar repo"

{
  test-exists \
    "$OWNER/bar/squash1.bin" \
    "$OWNER/bar/squash2.bin"

  test-lfs-file-content "$OWNER/bar/squash1.bin" "First squash file"
  test-lfs-file-content "$OWNER/bar/squash2.bin" "Second squash file"
}

# Test: LFS status and clean commands work
{
  status_output=$(
    cd "$OWNER/foo"
    git subrepo status bar
  )

  like "$status_output" \
    "Git subrepo 'bar':" \
    'Status command works with LFS subrepo'
}

# Test: Error handling with corrupted LFS file
{
  (
    cd "$OWNER/foo"
    echo "corrupted content" > bar/binary.bin
    git add bar/binary.bin
    git commit -m "Corrupt LFS file"
  ) &> /dev/null || die "Failed to create corrupted LFS scenario"

  # This should still work, git-subrepo should handle it gracefully
  push_output=$(
    cd "$OWNER/foo"
    git subrepo push bar 2>&1 || echo "PUSH_FAILED"
  )

  unlike "$push_output" "PUSH_FAILED" \
    'Push handles LFS file changes gracefully'
}

# Test: Mixed LFS/non-LFS scenario
note "Quick test of mixed LFS main repo with non-LFS subrepo"

# Create a temporary non-LFS subrepo for mixed testing
(
  mkdir -p "$TMP/mixed-test"
  cd "$TMP/mixed-test"
  git init --bare non-lfs-upstream
  git clone non-lfs-upstream non-lfs-repo
  cd non-lfs-repo
  echo "Regular file content" > regular.txt
  git add regular.txt
  git commit -m "Add regular file to non-LFS repo"
  git push
) &> /dev/null || die "Failed to create non-LFS test repo"

{
  mixed_clone_output=$(
    cd "$OWNER/foo"
    git subrepo clone "$TMP/mixed-test/non-lfs-upstream" mixed-repo
  )

  like "$mixed_clone_output" \
    "cloned into 'mixed-repo'" \
    'LFS main repo can clone non-LFS subrepo'

  # Verify both LFS and non-LFS files coexist
  test-exists \
    "$OWNER/foo/bar/binary.bin" \
    "$OWNER/foo/mixed-repo/regular.txt" \
    "!$OWNER/foo/mixed-repo/.gitattributes"
}

done_testing

teardown
