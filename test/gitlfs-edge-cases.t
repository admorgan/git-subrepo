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

note "Test git-subrepo LFS edge cases and error handling"

clone-foo-and-bar

# Edge Case 1: Subrepo with partial LFS tracking (some files tracked, some not)
note "Edge Case 1: Partial LFS tracking in subrepo"

(
  cd "$OWNER/bar"
  git lfs install --force
  git config lfs.url "$LFS_URL"
  git lfs track "*.big"
  # Only track .big files, not .txt files
  git add .gitattributes
  git commit -m "Partial LFS tracking"

  # Add mix of tracked and untracked files
  add-lfs-file "tracked.big" "This will be LFS tracked"
  echo "This will NOT be LFS tracked" > untracked.txt
  add-lfs-file "binary.big" "Binary LFS content for testing"

  git add untracked.txt
  git commit -m "Add mixed tracking files"
  git push
) &> /dev/null || die "Failed to setup partial LFS tracking in bar repo"

(
  cd "$OWNER/foo"
  git lfs install --force
  git config lfs.url "$LFS_URL"
  git config lfs.locksverify false
) &> /dev/null || die "Failed to setup LFS in foo repo"

{
  partial_clone_output=$(
    cd "$OWNER/foo"
    git subrepo clone "$UPSTREAM/bar"
  )

  is "$partial_clone_output" \
    "Subrepo '$UPSTREAM/bar' (master) cloned into 'bar'." \
    'Clone works with partial LFS tracking'

  # Ensure LFS files are present
  (
    cd "$OWNER/foo/bar"
    git lfs pull 2>/dev/null || true
    git lfs checkout 2>/dev/null || true
  ) &> /dev/null || die

  test-exists \
    "$OWNER/foo/bar/tracked.big" \
    "$OWNER/foo/bar/untracked.txt" \
    "$OWNER/foo/bar/binary.big" \
    "$OWNER/foo/bar/.gitattributes"

  # Check that only .big files are LFS tracked
  attrs_content=$(cat "$OWNER/foo/bar/.gitattributes")
  like "$attrs_content" "\*\.big.*filter=lfs" \
    'Partial LFS tracking preserved'
  unlike "$attrs_content" "\*\.txt.*filter=lfs" \
    'Non-LFS files remain untracked'
}

# Edge Case 2: Empty LFS repository
note "Edge Case 2: Empty LFS repository"

(
  mkdir -p "$TMP/empty-lfs"
  cd "$TMP/empty-lfs"
  git init --bare upstream-empty
  git clone upstream-empty empty-repo
  cd empty-repo
  git lfs install --force
  git lfs track "*.empty"
  git add .gitattributes
  git commit -m "LFS tracking without files"
  git push
) &> /dev/null || die

# Configure upstream bare repo for LFS
(
  cd "$TMP/empty-lfs/upstream-empty"
  git config lfs.allowincompletepush true
  git config receive.denyCurrentBranch updateInstead
  git config receive.denyNonFastForwards false
) &> /dev/null || die

{
  empty_clone_output=$(
    cd "$OWNER/foo"
    git subrepo clone "$TMP/empty-lfs/upstream-empty" empty-lfs
  )

  like "$empty_clone_output" \
    "cloned into 'empty-lfs'" \
    'Can clone empty LFS repository'

  test-exists \
    "$OWNER/foo/empty-lfs/.gitattributes" \
    "!$OWNER/foo/empty-lfs/any-files"

  attrs=$(cat "$OWNER/foo/empty-lfs/.gitattributes")
  like "$attrs" "\*\.empty.*filter=lfs" \
    'Empty LFS repo preserves tracking rules'
}

# Edge Case 3: LFS repository with binary files that exceed git limits
note "Edge Case 3: Large binary files"

(
  cd "$OWNER/bar"
  # Create a larger file (but not huge for test performance)
  dd if=/dev/zero of=large-binary.big bs=1024 count=50 2>/dev/null
  git add large-binary.big
  git commit -m "Add larger binary file"
  git push
) &> /dev/null || die

{
  large_pull_output=$(
    cd "$OWNER/foo"
    git subrepo pull bar
  )

  # Ensure LFS files are present
  (
    cd "$OWNER/foo/bar"
    git lfs pull 2>/dev/null || true
    git lfs checkout 2>/dev/null || true
  ) &> /dev/null || die

  is "$large_pull_output" \
    "Subrepo 'bar' pulled from '$UPSTREAM/bar' (master)." \
    'Can pull large LFS files'

  test-exists "$OWNER/foo/bar/large-binary.big"

  # Check file size
  file_size=$(stat -f%z "$OWNER/foo/bar/large-binary.big" 2>/dev/null || stat -c%s "$OWNER/foo/bar/large-binary.big" 2>/dev/null)
  is "$file_size" "51200" \
    'Large LFS file has correct size'
}

# Edge Case 4: Corrupted .gitattributes file
note "Edge Case 4: Corrupted LFS attributes"

(
  cd "$OWNER/foo"
  # Corrupt the .gitattributes in subrepo
  echo "invalid lfs syntax here" >> bar/.gitattributes
  git add bar/.gitattributes
  git commit -m "Corrupt LFS attributes"
) &> /dev/null || die

{
  corrupt_push_output=$(
    cd "$OWNER/foo"
    GIT_LFS_SKIP_PUSH=1 git subrepo push bar 2>&1 || echo "PUSH_FAILED"
  )

  # Should handle corruption gracefully
  unlike "$corrupt_push_output" "PUSH_FAILED" \
    'Handles corrupted .gitattributes gracefully'
}

# Edge Case 5: LFS file that becomes regular file
# Edge Case 5: LFS status command with mixed files
note "Edge Case 5: LFS status command with mixed files"

{
  status_output=$(
    cd "$OWNER/foo"
    git subrepo status bar
  )

  like "$status_output" \
    "Git subrepo 'bar':" \
    'Status command works with LFS subrepo'
}

done_testing 16

teardown
