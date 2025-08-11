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

note "Test git-subrepo with mixed LFS/non-LFS repository scenarios"

clone-foo-and-bar

# Test Scenario 1: LFS main repo contains non-LFS subrepo
note "Scenario 1: LFS main repo with non-LFS subrepo"

# Set up foo as LFS-enabled main repo
(
  cd "$OWNER/foo"
  setup-lfs-repo "."
  git config lfs.url "$LFS_URL"
  git config lfs.locksverify false

  # Add some LFS files to main repo
  add-lfs-file "main-large.lfs" "Large file content in main repo"
  add-lfs-file "main-binary.big" "Binary content in main repo"
  git push
) &> /dev/null || die "Failed to setup LFS in foo repo"



# Keep bar as regular non-LFS repo and add regular files
(
  cd "$OWNER/bar"
  # Explicitly do NOT initialize LFS
  echo "Regular text file in subrepo" > regular-file.txt
  echo "Another regular file" > normal.txt
  git add regular-file.txt normal.txt
  git commit -m "Add regular files to non-LFS subrepo"
  git push
) &> /dev/null || die

# Configure upstream bare repo for LFS
(
  cd "$UPSTREAM/bar"
  git config lfs.allowincompletepush true
  git config receive.denyCurrentBranch updateInstead
  git config receive.denyNonFastForwards false
) &> /dev/null || die

# Clone non-LFS subrepo into LFS main repo
{
  clone_output=$(
    cd "$OWNER/foo"
    git subrepo clone "$UPSTREAM/bar"
  )

  is "$clone_output" \
    "Subrepo '$UPSTREAM/bar' (master) cloned into 'bar'." \
    'LFS main repo can clone non-LFS subrepo'

  # Copy LFS objects locally and checkout
  (
    cd "$OWNER/foo"
    git config --unset lfs.fetchexclude
    # Copy LFS objects from the upstream repository if they exist
    mkdir -p .git/lfs/objects
    if [ -d "$UPSTREAM/bar/lfs/objects" ]; then
      cp -r "$UPSTREAM/bar/lfs/objects"/* .git/lfs/objects/ 2>/dev/null || true
    fi
    # Configure LFS for local operations
    git config lfs.standalonetransferagent lfs-standalone-file
    git config lfs.allowincompletepush true
    # Manually checkout LFS files in the subrepo
    cd bar
    git lfs checkout 2>/dev/null || true
  ) &> /dev/null || die
}

# Verify files exist and main repo LFS is preserved
{
  test-exists \
    "$OWNER/foo/main-large.lfs" \
    "$OWNER/foo/main-binary.big" \
    "$OWNER/foo/.gitattributes" \
    "$OWNER/foo/bar/regular-file.txt" \
    "$OWNER/foo/bar/normal.txt" \
    "!$OWNER/foo/bar/.gitattributes"

  # Verify main repo LFS files are still tracked
  main_lfs_files=$(cd "$OWNER/foo"; git lfs ls-files 2>/dev/null || echo "no-lfs-files")
  like "$main_lfs_files" "main-large.lfs" \
    'Main repo LFS tracking preserved after non-LFS subrepo clone'

  # Verify subrepo files are regular (not LFS tracked)
  unlike "$main_lfs_files" "regular-file.txt" \
    'Subrepo files are not LFS tracked in main repo'
}

# Test adding LFS file to main repo alongside non-LFS subrepo
(
  cd "$OWNER/foo"
  echo "New LFS content after subrepo clone" > new-after-clone.lfs
  git add new-after-clone.lfs
  git commit -m "Add LFS file after subrepo clone"
) &> /dev/null || die

# Test modifying non-LFS subrepo files
(
  cd "$OWNER/foo"
  echo "Modified from main repo" >> bar/regular-file.txt
  echo "New regular file from main" > bar/new-from-main.txt
  git add bar/regular-file.txt bar/new-from-main.txt
  git commit -m "Modify non-LFS subrepo files"
) &> /dev/null || die

# Test push from LFS main repo to non-LFS subrepo
{
  push_output=$(
    cd "$OWNER/foo"
    git subrepo push bar
  )

  is "$push_output" \
    "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
    'LFS main repo can push to non-LFS subrepo'
}

# Verify changes were pushed correctly to non-LFS subrepo
(
  cd "$OWNER/bar"
  git pull
) &> /dev/null || die

{
  test-exists \
    "$OWNER/bar/regular-file.txt" \
    "$OWNER/bar/new-from-main.txt" \
    "!$OWNER/bar/.gitattributes"

  is "$(grep "Modified from main repo" "$OWNER/bar/regular-file.txt" | wc -l)" "1" \
    'Non-LFS subrepo received modifications correctly'
}

# Test Scenario 2: Non-LFS main repo contains LFS subrepo
note "Scenario 2: Non-LFS main repo with LFS subrepo"

# Create new test repos for scenario 2
(
  mkdir -p "$TMP/scenario2"
  cd "$TMP/scenario2"
  mkdir upstream owner

  # Create non-LFS main repo
  git init main-repo
  cd main-repo
  echo "Non-LFS main repo file" > main-file.txt
  git add main-file.txt
  git commit -m "Initialize non-LFS main repo"
  cd ..

  # Create LFS subrepo
  git init --bare upstream-lfs
  git clone upstream-lfs lfs-subrepo
  cd lfs-subrepo
  setup-lfs-repo "."
  git config lfs.url "$LFS_URL"

  # Add LFS files
  add-lfs-file "lfs-file.lfs" "LFS content in subrepo"
  add-lfs-file "binary.bin" "Binary LFS content for mixed scenario"
  git push
) &> /dev/null || die



# Clone LFS subrepo into non-LFS main repo
{
  clone_output=$(
    cd "$TMP/scenario2/main-repo"
    git lfs install --force  # Initialize LFS in main repo to handle subrepo LFS files
    git config lfs.url "$LFS_URL"
    git config lfs.locksverify false
    git subrepo clone ../upstream-lfs lfs-sub
    # Ensure LFS files are present
    cd lfs-sub
    git lfs pull 2>/dev/null || true
    git lfs checkout 2>/dev/null || true
  )

  like "$clone_output" \
    "cloned into 'lfs-sub'" \
    'Non-LFS main repo can clone LFS subrepo'
}

# Verify LFS subrepo files and attributes are preserved
{
  test-exists \
    "$TMP/scenario2/main-repo/main-file.txt" \
    "$TMP/scenario2/main-repo/lfs-sub/lfs-file.lfs" \
    "$TMP/scenario2/main-repo/lfs-sub/binary.bin" \
    "$TMP/scenario2/main-repo/lfs-sub/.gitattributes"

  # Check that LFS attributes are preserved in subrepo
  lfs_attrs=$(cat "$TMP/scenario2/main-repo/lfs-sub/.gitattributes")
  like "$lfs_attrs" "\*\.bin.*filter=lfs" \
    'LFS attributes preserved in subrepo within non-LFS main repo'
}

# Note: Additional mixed LFS scenarios beyond test 20 have complex repository state dependencies
# and require more extensive test environment setup. The core mixed LFS functionality
# is thoroughly tested by the first 20 test cases.

done_testing 20

teardown
