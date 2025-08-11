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

note "Test that git-subrepo preserves LFS pointer files correctly"

clone-foo-and-bar

# Set up LFS in bar repo with actual LFS objects
(
  cd "$OWNER/bar"
  setup-lfs-repo "."
  git config lfs.url "$LFS_URL"

  # Create LFS files with known content
  add-lfs-file "file1.bin" "This is LFS content for file1"
  add-lfs-file "file2.lfs" "This is LFS content for file2"
  git push
) &> /dev/null || die "Failed to setup LFS in bar repo"

# Set up LFS in foo repo
(
  cd "$OWNER/foo"
  git lfs install
  git config lfs.url "$LFS_URL"
  git config lfs.locksverify false
) &> /dev/null || die "Failed to setup LFS in foo repo"

# Test: Clone and verify LFS pointers are preserved
clone_output=$(
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar"
)

is "$clone_output" \
  "Subrepo '$UPSTREAM/bar' (master) cloned into 'bar'." \
  'Subrepo clone with LFS pointers succeeds'

# Ensure LFS files are present
(
  cd "$OWNER/foo/bar"
  git lfs pull 2>/dev/null || true
  git lfs checkout 2>/dev/null || true
) &> /dev/null || die

# Check that .gitattributes was preserved
test-exists "$OWNER/foo/bar/.gitattributes"

# Verify LFS attributes are correct
attributes_content=$(cat "$OWNER/foo/bar/.gitattributes")
like "$attributes_content" "filter=lfs" \
  'LFS attributes preserved in cloned subrepo'

# Test: Verify LFS files have actual content (not pointers)
test-lfs-file-content "$OWNER/foo/bar/file1.bin" "This is LFS content for file1"
test-lfs-file-content "$OWNER/foo/bar/file2.lfs" "This is LFS content for file2"

# Test: Add new LFS file in subrepo and pull
(
  cd "$OWNER/bar"
  add-lfs-file "newfile.bin" "New LFS content from subrepo"
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
  'Subrepo pull preserves LFS pointers'

test-exists "$OWNER/foo/bar/newfile.bin"
test-lfs-file-content "$OWNER/foo/bar/newfile.bin" "New LFS content from subrepo"

# Test: Modify LFS file in main repo and push
(
  cd "$OWNER/foo"
  add-lfs-file "bar/file1.bin" "Modified LFS content from main repo"
) &> /dev/null || die "Failed to modify LFS file in main repo"

push_output=$(
  cd "$OWNER/foo"
  git subrepo push bar
)

is "$push_output" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  'Subrepo push preserves LFS pointers'

# Verify the change made it to the subrepo
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull pushed changes"

test-exists "$OWNER/bar/file1.bin"
test-lfs-file-content "$OWNER/bar/file1.bin" "Modified LFS content from main repo"

# Test: LFS pointer integrity after branch operation
(
  cd "$OWNER/foo"
  add-lfs-file "bar/branch.bin" "Branch test LFS content"
) &> /dev/null || die "Failed to add LFS file for branch test"

# Fetch to sync subrepo state before branch operation
(
  cd "$OWNER/foo"
  git subrepo fetch bar
) &> /dev/null || die "Failed to fetch subrepo state"

branch_output=$(
  cd "$OWNER/foo"
  git subrepo branch bar
)

is "$branch_output" \
  "Created branch 'subrepo/bar' and worktree '.git/tmp/subrepo/bar'." \
  'Subrepo branch preserves LFS pointers'

# Check that LFS files exist in branch worktree
test-exists "$OWNER/foo/.git/tmp/subrepo/bar/branch.bin"

# Clean up branch
(
  cd "$OWNER/foo"
  git subrepo clean bar
) &> /dev/null || die "Failed to clean subrepo branch"

# Test: Squash preserves LFS pointers
(
  cd "$OWNER/foo"
  add-lfs-file "bar/squash1.bin" "First squash LFS file"
  add-lfs-file "bar/squash2.bin" "Second squash LFS file"
) &> /dev/null || die "Failed to add LFS files for squash test"

squash_output=$(
  cd "$OWNER/foo"
  git subrepo push bar --squash
)

is "$squash_output" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  'Subrepo squash push preserves LFS pointers'

# Verify squashed LFS files
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die "Failed to pull squashed changes"

test-exists \
  "$OWNER/bar/squash1.bin" \
  "$OWNER/bar/squash2.bin"

test-lfs-file-content "$OWNER/bar/squash1.bin" "First squash LFS file"
test-lfs-file-content "$OWNER/bar/squash2.bin" "Second squash LFS file"

# Final verification: Check that .gitrepo file doesn't contain LFS pointers
gitrepo_content=$(cat "$OWNER/foo/bar/.gitrepo")
unlike "$gitrepo_content" "version https://git-lfs.github.com/spec" \
  '.gitrepo file does not contain LFS pointers'

done_testing

teardown
