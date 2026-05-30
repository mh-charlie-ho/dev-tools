#!/bin/bash

CONFIG_FILENAME="branch_maintain.conf"
CONFIG_FILE="$(pwd)/$CONFIG_FILENAME"
EXCLUDE_FILE="$(pwd)/.git/info/exclude"
GITIGNORE_FILE="$(pwd)/.gitignore"

# ==================================================
# Config template
# ==================================================
write_config_template() {
    cat > "$CONFIG_FILE" << 'EOF'
# ==================== branch maintainer config ====================
# Edit this file to configure your branches.
# The script itself never needs to be modified.
# ==================================================================

# Main branch name
MASTER_BRANCH="master"

# Report output path
REPORT_FILE="./daily_report.txt"

# Test command (simple commands only; wrap complex ones in a script)
# Leave empty to skip tests entirely: TEST_COMMAND=""
TEST_COMMAND="make test"

# Required tools (no need to change this normally)
REQUIRED_CMDS=("git")

# --------------------------------------------------
# 1. Unordered branches (each rebased onto master independently)
# --------------------------------------------------
UNORDERED_BRANCHES=(
  # "feature-your-branch"
)

# --------------------------------------------------
# 2. Ordered dependency chains
#    Comma-separated, left is upstream, right is downstream
#    Example: master -> feature-base -> feature-dependent
# --------------------------------------------------
ORDERED_GROUPS=(
  # "feature-base,feature-dependent"
)
EOF
}

# ==================================================
# Check if config is already ignored
# Returns 0 = already ignored, 1 = not ignored
# ==================================================
is_already_ignored() {
    if [ -f "$EXCLUDE_FILE" ] && grep -qF "$CONFIG_FILENAME" "$EXCLUDE_FILE" 2>/dev/null; then
        return 0
    fi
    if [ -f "$GITIGNORE_FILE" ] && grep -qF "$CONFIG_FILENAME" "$GITIGNORE_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# ==================================================
# Ask where to ignore the config file (asked once only)
# ==================================================
ask_ignore() {
    echo ""
    echo "📋 Add $CONFIG_FILENAME to an ignore list?"
    echo "   This prevents it from showing up in git status."
    echo ""
    echo "   [1] .git/info/exclude  (local only, recommended)"
    echo "   [2] .gitignore         (committed to repo, affects everyone)"
    echo "   [3] Skip"
    echo ""
    read -rp "Choice [1/2/3]: " choice

    case "$choice" in
        1)
            mkdir -p "$(dirname "$EXCLUDE_FILE")"
            echo "$CONFIG_FILENAME" >> "$EXCLUDE_FILE"
            echo "✅ Added to .git/info/exclude."
            ;;
        2)
            echo "$CONFIG_FILENAME" >> "$GITIGNORE_FILE"
            echo "✅ Added to .gitignore."
            ;;
        3)
            echo "⏭️  Skipped. Won't ask again."
            ;;
        *)
            echo "⚠️  Invalid choice. Skipped. Won't ask again."
            ;;
    esac

    # Write flag regardless of choice so we never ask again
    echo '' >> "$CONFIG_FILE"
    echo '# Ignore prompt completed (do not remove this line)' >> "$CONFIG_FILE"
    echo 'IGNORE_PROMPT_DONE="true"' >> "$CONFIG_FILE"

    echo ""
}

# ==================================================
# Config initialization
# ==================================================
init_config() {
    # Case A: config does not exist
    if [ ! -f "$CONFIG_FILE" ]; then
        echo ""
        echo "⚠️  No $CONFIG_FILENAME found in current directory."
        echo "   Creating template..."
        write_config_template
        echo "✅ Created: $CONFIG_FILE"
        echo ""
        echo "👉 Open the config file, fill in your branches, then run the script again:"
        echo "   \$EDITOR $CONFIG_FILE"
        echo ""

        if ! is_already_ignored; then
            ask_ignore
        fi

        exit 0
    fi

    # Case B: config exists but no branches configured yet
    source "$CONFIG_FILE"
    if [ ${#UNORDERED_BRANCHES[@]} -eq 0 ] && [ ${#ORDERED_GROUPS[@]} -eq 0 ]; then
        echo ""
        echo "⚠️  Config exists but no branches have been added yet."
        echo "   Add at least one branch to UNORDERED_BRANCHES or ORDERED_GROUPS:"
        echo "   \$EDITOR $CONFIG_FILE"
        echo ""
        exit 0
    fi

    # Case C: config is valid but not yet ignored and never asked — ask once
    if ! is_already_ignored && [ "${IGNORE_PROMPT_DONE:-false}" != "true" ]; then
        ask_ignore
    fi
}

init_config


# ==================================================
# Cleanup on exit or interrupt
# ==================================================
cleanup() {
    git rebase --abort > /dev/null 2>&1
    git checkout "$MASTER_BRANCH" > /dev/null 2>&1
}
trap cleanup EXIT INT TERM


# ==================================================
# Process a single branch
# Returns: 0=success 1=conflict 2=test failed 3=push failed 4=checkout failed
# ==================================================
process_branch() {
    local branch="$1"
    local upstream="$2"

    if ! git checkout "$branch" > /dev/null 2>&1; then
        echo "  ❌ $branch: Could not switch branch (uncommitted changes or branch missing)."
        return 4
    fi
    if [ "$(git rev-parse --abbrev-ref HEAD)" != "$branch" ]; then
        echo "  ❌ $branch: HEAD is not on expected branch after checkout. Aborting."
        return 4
    fi

    local orig_head
    orig_head="$(git rev-parse HEAD)"

    git rebase "$upstream" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "  ❌ $branch: Rebase conflict. Rolled back."
        git rebase --abort > /dev/null 2>&1
        return 1
    fi

    if [ -n "$TEST_COMMAND" ]; then
        $TEST_COMMAND > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "  ⚠️  $branch: Tests failed. Rolled back to pre-rebase state."
            git reset --hard "$orig_head" > /dev/null 2>&1
            return 2
        fi
    else
        echo "  ⏭️  $branch: No test command configured, skipping tests."
    fi

    git push origin "$branch" --force-with-lease > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "  ❌ $branch: Push failed. Rolled back to pre-rebase state."
        git reset --hard "$orig_head" > /dev/null 2>&1
        return 3
    fi

    echo "  ✅ $branch: Successfully rebased onto '$upstream'."
    return 0
}


# ==================================================
# Step 1/5 — Check dependencies
# ==================================================
echo "🔍 [Step 1/5] Checking dependencies..."
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Required tool not found: $cmd. Please install it first."
        exit 1
    fi
done
echo "🎉 All dependencies satisfied."

# ==================================================
# Step 2/5 — Pre-flight checks
# ==================================================
echo "--------------------------------------------------"
echo "🔍 [Step 2/5] Running pre-flight checks..."

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    echo "❌ Working directory has uncommitted changes. Please commit or stash first."
    exit 1
fi

ALL_BRANCHES=("${UNORDERED_BRANCHES[@]}")
for g in "${ORDERED_GROUPS[@]}"; do
    IFS=',' read -r -a _parts <<< "$g"
    ALL_BRANCHES+=("${_parts[@]}")
done
MISSING=()
for b in "${ALL_BRANCHES[@]}"; do
    git rev-parse --verify "$b" > /dev/null 2>&1 || MISSING+=("$b")
done
if [ ${#MISSING[@]} -ne 0 ]; then
    echo "❌ The following branches do not exist. Please fix the config and try again:"
    printf '   - %s\n' "${MISSING[@]}"
    exit 1
fi
echo "🎉 Pre-flight checks passed."

# ==================================================
# Step 3/5 — Initialize report and sync master
# ==================================================
echo "--------------------------------------------------"
echo "🔍 [Step 3/5] Initializing report and syncing master..."

echo "=== Branch Maintainer Report ($(date)) ===" > "$REPORT_FILE"
echo "Config: $CONFIG_FILE" >> "$REPORT_FILE"
echo "Status: in progress" >> "$REPORT_FILE"
echo "--------------------------------------------------" >> "$REPORT_FILE"

if ! git checkout "$MASTER_BRANCH" > /dev/null 2>&1; then
    echo "❌ Could not switch to $MASTER_BRANCH. Aborting."
    exit 1
fi
if ! git pull origin "$MASTER_BRANCH" > /dev/null 2>&1; then
    echo "❌ Could not update $MASTER_BRANCH (network or conflict). Aborting to avoid rebasing onto a stale base."
    exit 1
fi

SUCCESS_LIST=()
CONFLICT_LIST=()
TEST_FAIL_LIST=()
SKIP_LIST=()

# ==================================================
# Step 4/5 — Stage 1: Unordered branches
# ==================================================
echo "--------------------------------------------------"
echo "🚀 [Stage 1] Processing unordered branches..."

for BRANCH in "${UNORDERED_BRANCHES[@]}"; do
    echo "⚙️  $BRANCH -> $MASTER_BRANCH"
    process_branch "$BRANCH" "$MASTER_BRANCH"
    case $? in
        0) SUCCESS_LIST+=("[unordered] $BRANCH") ;;
        1) CONFLICT_LIST+=("[unordered] $BRANCH") ;;
        2) TEST_FAIL_LIST+=("[unordered] $BRANCH (test failed)") ;;
        3) TEST_FAIL_LIST+=("[unordered] $BRANCH (push failed)") ;;
        4) TEST_FAIL_LIST+=("[unordered] $BRANCH (checkout failed)") ;;
    esac
done

# ==================================================
# Step 5/5 — Stage 2: Ordered dependency chains
# ==================================================
echo "--------------------------------------------------"
echo "🚀 [Stage 2] Processing ordered dependency chains..."

GROUP_COUNTER=1
for GROUP_STR in "${ORDERED_GROUPS[@]}"; do
    echo "📦 Chain $GROUP_COUNTER..."
    IFS=',' read -r -a GROUP_BRANCHES <<< "$GROUP_STR"

    UPSTREAM_TARGET="$MASTER_BRANCH"
    CHAIN_BROKEN=false

    for BRANCH in "${GROUP_BRANCHES[@]}"; do
        if [ "$CHAIN_BROKEN" = true ]; then
            echo "  ⏭️  $BRANCH: Skipped (upstream in chain failed)."
            SKIP_LIST+=("[chain$GROUP_COUNTER] $BRANCH")
            continue
        fi

        echo "  ⛓️  $BRANCH -> $UPSTREAM_TARGET"
        process_branch "$BRANCH" "$UPSTREAM_TARGET"
        case $? in
            0)
                SUCCESS_LIST+=("[chain$GROUP_COUNTER] $BRANCH")
                UPSTREAM_TARGET="$BRANCH"
                ;;
            1)
                CONFLICT_LIST+=("[chain$GROUP_COUNTER] $BRANCH")
                CHAIN_BROKEN=true
                ;;
            2)
                TEST_FAIL_LIST+=("[chain$GROUP_COUNTER] $BRANCH (test failed)")
                CHAIN_BROKEN=true
                ;;
            3)
                TEST_FAIL_LIST+=("[chain$GROUP_COUNTER] $BRANCH (push failed)")
                CHAIN_BROKEN=true
                ;;
            4)
                TEST_FAIL_LIST+=("[chain$GROUP_COUNTER] $BRANCH (checkout failed)")
                CHAIN_BROKEN=true
                ;;
        esac
    done

    ((GROUP_COUNTER++))
done

# ==================================================
# Report
# ==================================================
write_list() {
    local title="$1"; shift
    echo "" >> "$REPORT_FILE"
    echo "$title" >> "$REPORT_FILE"
    if [ $# -eq 0 ]; then
        echo "  (none)" >> "$REPORT_FILE"
    else
        printf '  - %s\n' "$@" >> "$REPORT_FILE"
    fi
}

echo "" >> "$REPORT_FILE"
echo "📊 Summary" >> "$REPORT_FILE"
write_list "✅ Succeeded:" "${SUCCESS_LIST[@]}"
write_list "⚠️  Conflicts (rolled back):" "${CONFLICT_LIST[@]}"
write_list "❌ Test or push failures (rolled back):" "${TEST_FAIL_LIST[@]}"
write_list "⏭️  Skipped (upstream failed):" "${SKIP_LIST[@]}"

if [ ${#CONFLICT_LIST[@]} -eq 0 ] && [ ${#TEST_FAIL_LIST[@]} -eq 0 ] && [ ${#SKIP_LIST[@]} -eq 0 ]; then
    FINAL_STATUS="all succeeded"
else
    FINAL_STATUS="completed with issues (see report)"
fi
sed -i "s/Status: in progress/Status: $FINAL_STATUS/g" "$REPORT_FILE"

echo "--------------------------------------------------"
echo "🎉 Done. See daily_report.txt for details."
cat "$REPORT_FILE"