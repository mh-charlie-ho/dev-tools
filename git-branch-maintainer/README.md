# git-branch-maintainer

A Bash script that automatically rebases, tests, and force-pushes your personal feature branches every day — keeping them aligned with `master` without manual effort.

Designed for **solo developers** managing multiple feature branches across large repos.

---

## How It Works

The script processes branches in two stages:

**Stage 1 — Unordered branches**: Each branch is independently rebased onto `master`. Failures are isolated and do not affect other branches.

**Stage 2 — Ordered dependency chains**: Branches are processed in sequence where each branch rebases onto the previous one. If a branch fails, all downstream branches in the same chain are automatically skipped (circuit breaker).

For every branch, the script:
1. Switches to the branch and verifies the checkout
2. Records the pre-rebase HEAD
3. Rebases onto the upstream target
4. Runs your test command
5. Force-pushes with `--force-with-lease`
6. Rolls back to the pre-rebase HEAD on any failure

A daily report is written to `daily_report.txt` summarizing what succeeded, failed, or was skipped.

---

## Project Structure

```
dev-tools/
└── git-branch-maintainer/
    ├── maintain.sh   # The script — lives in your tools repo, never copied
    └── README.md
```

```
your-project-repo/
└── branch_maintain.conf           # Per-repo config — lives alongside your code
```

---

## Setup

**1. Clone this repo somewhere central:**
```bash
git clone https://github.com/your-username/dev-tools.git ~/dev-tools
```

**2. Make the script executable:**
```bash
chmod +x ~/dev-tools/git-branch-maintainer/maintain.sh
```

**3. Run it from inside your project repo:**
```bash
cd ~/projects/your-repo
~/dev-tools/git-branch-maintainer/maintain.sh
```

On first run, the script will:
- Generate a `branch_maintain.conf` template in your project directory
- Ask whether to add it to `.git/info/exclude` or `.gitignore` (asked once only)
- Exit and prompt you to fill in the config

**4. Edit the config and run again:**
```bash
$EDITOR branch_maintain.conf
~/dev-tools/git-branch-maintainer/maintain.sh
```

---

## Configuration

`branch_maintain.conf` is placed in each project repo and never committed (see [Keeping the config private](#keeping-the-config-private)).

```bash
MASTER_BRANCH="master"       # Your main branch
REPORT_FILE="./daily_report.txt"
TEST_COMMAND="make test"     # Simple commands only; wrap complex ones in a script

# Branches rebased independently onto master
UNORDERED_BRANCHES=(
  "feature-payments"
  "feature-docs"
)

# Dependency chains: left is upstream, right is downstream
# master -> feature-ui-core -> feature-login-page
ORDERED_GROUPS=(
  "feature-ui-core,feature-login-page"
)
```

---

## Keeping the Config Private

The config file contains only your personal branch names and is not meant to be committed to a shared repo. The script will ask where to ignore it on first run:

- **`.git/info/exclude`** — recommended. Local only, invisible to teammates, no effect on the repo.
- **`.gitignore`** — adds it to the shared ignore list, visible to everyone.
- **Skip** — do nothing. The script will not ask again.

To add it manually at any time:
```bash
echo "branch_maintain.conf" >> .git/info/exclude
```

---

## Safety Features

| Feature | Detail |
|---|---|
| Dirty working tree check | Aborts if there are uncommitted changes |
| Branch existence check | Validates all branches in config before starting |
| Pre-rebase HEAD snapshot | Rolls back to exact pre-rebase state on failure, not `origin/branch` |
| Checkout verification | Confirms HEAD is on the expected branch after switching |
| Circuit breaker | A failure in an ordered chain skips all downstream branches |
| `master` pull guard | Aborts if `master` cannot be updated, preventing rebases onto a stale base |
| `trap` cleanup | On interrupt or crash, aborts any in-progress rebase and returns to `master` |
| `--force-with-lease` | Refuses to push if the remote was updated by someone else since your last fetch |

---

## ⚠️ Important: Personal Branches Only

This script uses `rebase` + `force-push`, which rewrites commit history. It is safe **only on branches you own exclusively**. Never add shared or collaborative branches to the config.