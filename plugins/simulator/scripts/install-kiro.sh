#!/bin/sh
# install-kiro.sh — set up or package the simulator plugin for AWS Kiro.
#
# Usage:
#   plugins/simulator/scripts/install-kiro.sh [workspace-dir]
#     Install into an existing Kiro workspace (default mode). Creates the
#     following under <workspace>/.kiro/:
#       settings/mcp.json        ← generated from .mcp.kiro.json with the
#                                  ${KIRO_PLUGIN_ROOT:-$PWD/.kiro/..} probe
#                                  resolved to an absolute path
#       steering/<name>.md       ← symlinked from this plugin's steering/
#       skills/<name>/SKILL.md   ← HARD-COPIED with $CLAUDE_PLUGIN_ROOT
#                                  resolved to the absolute plugin path
#     workspace-dir defaults to $KIRO_WORKSPACE_DIR or $PWD. Also always
#     runs --install-power below in the same invocation, so the plugin
#     stays registered as a Kiro Power globally, not just in this one
#     workspace.
#
#   plugins/simulator/scripts/install-kiro.sh --power [output-dir]
#     Build a portable, importable Kiro Power bundle instead of installing
#     into a workspace (Powers panel → Add Custom Power → Import from
#     folder). Generates:
#       POWER.md             (metadata + onboarding + steering routing table
#                             — a disposable build artifact, NOT the tracked
#                             repo-root POWER.md; see the versioning note
#                             below)
#       mcp.json              (copy of .mcp.kiro.json, with PLUGIN_ROOT
#                              resolved to THIS clone's absolute path — see
#                              "Why an absolute path, not a runtime probe"
#                              below)
#       steering/<name>.md    (one per skill, frontmatter stripped, plus
#                              steering/simulator-guardrails.md — the
#                              plugin's own always-on steering file, renamed
#                              on copy to avoid colliding with the
#                              "simulator" skill's own steering/simulator.md)
#     Reads (never writes) the version from .claude-plugin/plugin.json.
#     `make release` owns bumping that number in lockstep across the six
#     tracked manifests (see AGENTS.md → "Versioning & releases") and fails
#     if it finds them out of lockstep — this script must not fight that
#     drift check by writing a seventh, script-local copy of the version.
#     output-dir defaults to <repo-root>/power-simulator/.
#
#   plugins/simulator/scripts/install-kiro.sh --install-power
#     Build the bundle (as --power does, into <repo-root>/power-simulator/)
#     and install it directly into this machine's local Kiro, bypassing the
#     Powers panel's "Import from folder" UI:
#       ~/.kiro/powers/installed/power-simulator/   ← the bundle, copied
#       ~/.kiro/powers/installed.json               ← registers the power
#     Restart Kiro (or reload window) afterwards — there's no CLI to
#     hot-reload a newly installed power.
#
# Why an absolute path, not a runtime probe, for the bundle's mcp.json?
#   A sibling plugin's equivalent script leaves its bundle's PLUGIN_ROOT as a
#   runtime probe (${KIRO_PLUGIN_ROOT:-$PWD}) that resolves wherever the
#   bundle lands, because that plugin's whole MCP server payload travels
#   inside the bundle. Simulator's MCP server is a Go program launched via
#   mcp-server/run.sh (self-downloads a prebuilt binary from GitHub Releases,
#   falling back to `go run` from source) — and Kiro's own import step
#   (Powers panel "Import from folder", and this script's own
#   --install-power) keeps only POWER.md, mcp.json, and steering/ from
#   whatever folder it's given. mcp-server/ would never survive into the
#   installed bundle, so a runtime probe would resolve PLUGIN_ROOT to a path
#   with no run.sh at all — the self-heal fallback in .mcp.kiro.json would
#   exhaust both candidates and exit with "cannot locate mcp-server/run.sh".
#   Pointing the bundle's mcp.json straight at this clone's absolute
#   mcp-server/ path instead means it keeps working as long as this clone
#   stays on disk — the same tradeoff workspace-install mode and the
#   steering doc-references below already make; the bundle is no longer
#   portable to a different machine's clone, but for this plugin that
#   portability was never available to begin with.
#
# Why hard-copy and resolve the $CLAUDE_PLUGIN_ROOT token, instead of
# symlinking the source files the way Claude Code / Codex consume them?
#   - The token `$CLAUDE_PLUGIN_ROOT` is a host-side text substitution Claude
#     Code performs at skill-load time (anthropics/claude-code#48230 etc.).
#     Kiro does no such substitution — so the literal `$CLAUDE_PLUGIN_ROOT`
#     would survive into the model context, leaving every reference-doc path
#     as a dead string. Resolving the token at build/install time fixes that.
#   - Symlinked skills would re-introduce the unresolved token on every read,
#     which is why both modes hard-copy skills but can still symlink
#     steering/ in workspace-install mode (small, stable, no token to
#     resolve there).
#
# `sed -i` portability is handled with the `-i.bak`+`find -delete` two-step
# (works under both GNU sed on Linux and BSD sed on macOS without branching).
#
# Idempotent — safe to run repeatedly; each mode regenerates its output from
# scratch.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SKILLS_DIR="$PLUGIN_ROOT/skills"

# Escape \, & and our sed delimiter so a stray one of those in PLUGIN_ROOT
# (e.g. a `#` in the clone path) can't corrupt a replacement.
PLUGIN_ROOT_ESCAPED="$(printf '%s\n' "$PLUGIN_ROOT" | sed 's/[\&#]/\\&/g')"

# ─── Mode: install into an existing Kiro workspace ──────────────────────────

run_workspace_install() {
  WORKSPACE="${1:-${KIRO_WORKSPACE_DIR:-$PWD}}"
  KIRO_DIR="$WORKSPACE/.kiro"

  if [ ! -d "$WORKSPACE" ]; then
    echo "ERROR: workspace dir not found: $WORKSPACE" >&2
    exit 1
  fi

  mkdir -p "$KIRO_DIR/settings" "$KIRO_DIR/steering" "$KIRO_DIR/skills"

  # 1) MCP entry — resolve the KIRO_PLUGIN_ROOT fallback in .mcp.kiro.json to
  #    the known absolute PLUGIN_ROOT so the generated mcp.json works without
  #    the env var being set.
  sed 's#\${KIRO_PLUGIN_ROOT:-\$PWD/.kiro/..}#'"$PLUGIN_ROOT_ESCAPED"'#g' \
    "$PLUGIN_ROOT/.mcp.kiro.json" > "$KIRO_DIR/settings/mcp.json"

  # 2) Steering — small, stable, no token substitution needed. Symlink on
  #    POSIX, hard-copy on Windows shells.
  case "$(uname -s 2>/dev/null || echo Unknown)" in
    MINGW*|CYGWIN*|MSYS*) STEERING_LINK="cp -R" ;;
    *)                    STEERING_LINK="ln -sfn" ;;
  esac
  for f in "$PLUGIN_ROOT"/steering/*.md; do
    [ -f "$f" ] || continue
    $STEERING_LINK "$f" "$KIRO_DIR/steering/$(basename "$f")"
  done

  # 3) Skills — HARD-COPY then sed-substitute $CLAUDE_PLUGIN_ROOT in every .md
  #    so reference-doc paths resolve to the absolute plugin dir under Kiro.
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    name="$(basename "$d")"
    dst="$KIRO_DIR/skills/$name"
    rm -rf "$dst"
    cp -R "$d" "$dst"
    # `#` delimiter avoids escaping the `/` inside $PLUGIN_ROOT. Backup suffix
    # is the portable two-step for GNU and BSD sed.
    find "$dst" -name '*.md' -type f -exec \
      sed -i.bak "s#\\\$CLAUDE_PLUGIN_ROOT#$PLUGIN_ROOT#g" {} +
    find "$dst" -name '*.md.bak' -type f -delete
  done

  echo "Installed simulator plugin into: $KIRO_DIR"
  echo "Open this workspace in Kiro and the simulator MCP server, skills, and steering will be picked up."
  echo "Reference-doc paths in skills were resolved to: $PLUGIN_ROOT"
  echo
  echo "If your shell does not already set KIRO_PLUGIN_ROOT, add:"
  echo "  export KIRO_PLUGIN_ROOT=\"$PLUGIN_ROOT\""
}

# ─── Mode: build a portable Kiro Power bundle ───────────────────────────────

run_power_build() {
  OUTPUT_DIR="${1:-$REPO_ROOT/power-simulator}"

  VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$PLUGIN_ROOT/.claude-plugin/plugin.json" | head -1)
  if [ -z "$VERSION" ]; then
    echo "ERROR: could not read version from .claude-plugin/plugin.json" >&2
    exit 1
  fi

  rm -rf "$OUTPUT_DIR"
  mkdir -p "$OUTPUT_DIR/steering"

  # MCP entry — same absolute-path resolution as workspace-install mode (see
  # the "Why an absolute path" header note on why this bundle can't leave
  # PLUGIN_ROOT as a runtime-resolving probe).
  sed 's#\${KIRO_PLUGIN_ROOT:-\$PWD/.kiro/..}#'"$PLUGIN_ROOT_ESCAPED"'#g' \
    "$PLUGIN_ROOT/.mcp.kiro.json" > "$OUTPUT_DIR/mcp.json"

  # Plugin's own always-on guardrails file — renamed on copy since the
  # "simulator" skill below would otherwise also produce steering/simulator.md.
  if [ -f "$PLUGIN_ROOT/steering/simulator.md" ]; then
    awk '
      BEGIN { count=0 }
      /^---$/ { count++; next }
      count >= 2 { print }
    ' "$PLUGIN_ROOT/steering/simulator.md" > "$OUTPUT_DIR/steering/simulator-guardrails.md"
  fi

  # Convert each skill to a steering file
  skill_count=0
  for d in "$SKILLS_DIR"/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/SKILL.md" ] || continue
    skill_count=$((skill_count + 1))

    name=$(basename "$d")
    steering_file="$OUTPUT_DIR/steering/${name}.md"

    # Extract body (everything after closing ---) and write as steering
    # file, resolving $CLAUDE_PLUGIN_ROOT to this clone's absolute path (see
    # the --power header note on why the bundle isn't machine-portable
    # instead). Handles both ${CLAUDE_PLUGIN_ROOT} (braced) and
    # $CLAUDE_PLUGIN_ROOT (unbraced) forms, though simulator's skills only
    # use the unbraced form today.
    awk '
      BEGIN { count=0 }
      /^---$/ { count++; next }
      count >= 2 { print }
    ' "$d/SKILL.md" | sed \
      -e "s#\\\${CLAUDE_PLUGIN_ROOT}#$PLUGIN_ROOT#g" \
      -e "s#\\\$CLAUDE_PLUGIN_ROOT#$PLUGIN_ROOT#g" > "$steering_file"

    # Append reference files inline if they exist
    if [ -d "$d/references" ]; then
      for ref in "$d/references"/*.md; do
        [ -f "$ref" ] || continue
        ref_name=$(basename "$ref")
        printf '\n---\n\n## Reference: %s\n\n' "$ref_name" >> "$steering_file"
        sed \
          -e "s#\\\${CLAUDE_PLUGIN_ROOT}#$PLUGIN_ROOT#g" \
          -e "s#\\\$CLAUDE_PLUGIN_ROOT#$PLUGIN_ROOT#g" "$ref" >> "$steering_file"
      done
    fi

    # Append template files inline if they exist
    for tmpl in "$d"/template.*; do
      [ -f "$tmpl" ] || continue
      tmpl_name=$(basename "$tmpl")
      ext="${tmpl_name##*.}"
      printf '\n---\n\n## Template: %s\n\n```%s\n' "$tmpl_name" "$ext" >> "$steering_file"
      cat "$tmpl" >> "$steering_file"
      printf '\n```\n' >> "$steering_file"
    done
  done

  # Generate POWER.md — a disposable build artifact regenerated from scratch
  # every run. Distinct from the tracked repo-root POWER.md, whose version is
  # bumped only by `make release` in lockstep with the other five manifests.
  cat > "$OUTPUT_DIR/POWER.md" << FRONTMATTER
---
name: "simulator"
displayName: "Simulator.Company"
version: "$VERSION"
description: "BPM, graph, and financial-tracking toolkit for the Simulator.Company platform. Exposes the Simulator REST API as MCP tools plus $skill_count steering files covering actors, forms, graphs, layers, accounts, transactions, transfers, charts, smart forms, meetings, reactions, tasks, and attachments."
keywords: ["simulator", "bpm", "business-process", "graph", "financial", "actors", "forms", "mcp"]
author: "Simulator.Company"
---

# Simulator.Company Power

## Onboarding

### Step 1: Choose an environment

Call the MCP tool \`set-environment\` with a \`preset\` (\`mw\` or \`sim\` for
Simulator Cloud) or a custom/on-prem \`url\`. Always let the user choose — there
is no default environment.

### Step 2: Authenticate

Call \`login\` with no arguments. It opens a browser for OAuth2 (PKCE) sign-in
against the account URL derived in Step 1 and saves the token to \`.env\` as
\`ACCESS_TOKEN\`.

### Step 3: Choose a workspace

Call \`getWorkspaces\` to list workspaces by name, let the user pick, then call
\`set-workspace(name="...")\` (or \`accId="..."\`) to save it as the default
workspace.

### Step 4: Verify

Call \`getWorkspaces\` again — if it returns your workspace list, you're
connected.

FRONTMATTER

  cat >> "$OUTPUT_DIR/POWER.md" << 'ROUTING'
## When to Load Steering Files

- Workspace context check (`accId`), tool routing, language policy — applies
  to every interaction, load first → `simulator-guardrails.md`
- General Simulator questions, universal entry point, platform overview → `simulator.md`
- First-time setup: environment selection, OAuth login, workspace selection → `simulator-init.md`
- Sharing/access: who can view/modify/sign/execute an object, grant/revoke, request access → `simulator-access.md`
- Actor (record) CRUD: create/update/search/filter actor data, form-instance data protocol, an actor's connected processes/API keys → `simulator-actors.md`
- Digital-twin agents: talk to a person/service as an agent, delegate work by competency → `simulator-agents.md`
- Files & attachments: upload, attach/detach to actors & reactions, list workspace files → `simulator-attachments.md`
- Charts & dashboards: create/configure/query line/bar/area/funnel charts on a layer → `simulator-charts.md`
- Chat & messaging: p2p/group chats, sending messages to a user → `simulator-chat.md`
- Financial accounts: balances, counters, transactions, transfers, currencies, account triggers → `simulator-finance.md`
- Form templates (Account Templates): field structure, system forms → `simulator-forms.md`
- Graph structure: actors (nodes), links (edges), layers, FlowchartBlock diagrams, push/pull/sync → `simulator-graph.md`
- Meetings/video/SIP rooms: schedule, recurrence, agenda, join links, call transcription → `simulator-meetings.md`
- Reactions: comments, approvals, ratings, threads on an actor → `simulator-reactions.md`
- Skill registry: run or author a saved data-driven playbook (`Skills` system form) → `simulator-skills.md`
- Smart Form design: pages, viewModel, locale, widgets, pull/push/deploy/releases → `simulator-smart-forms.md`
- Smart Form backend logic: wire a Smart Form to Corezoid processes, submit handlers → `simulator-smart-forms-logic.md`
- Smart Form runtime: run/execute an existing Smart Form flow conversationally → `simulator-smart-forms-runtime.md`
- Smart Form styling: Less/CSS theming, component re-skinning, design systems → `simulator-styles.md`
- Tasks & assignments: create a task, assign executor/approvers/signers, order/directive documents → `simulator-tasks.md`

ROUTING

  cat >> "$OUTPUT_DIR/POWER.md" << 'FOOTER'
## MCP Tools (highlights)

| Tool | What it does |
|---|---|
| `login` | OAuth2 browser login; saves token to `~/.simulator/` / `.env`. |
| `set-environment` | Pick a cloud preset or custom/on-prem gateway URL. |
| `set-workspace` | Pick the active workspace by id or name. |
| `pullGraphFile` / `pushGraphFile` | Export / sync a layer as YAML. |
| `createActor` / `updateActor` / `deleteActor` | Single-actor CRUD. |
| `compactGraphLayout` | Auto-layout actors with domain-clustering. |
| `pruneLongEdges` | Delete edges exceeding a Manhattan distance threshold. |
| `getAllLayerPlacements` | One call returns every placement on a layer. |
| `uploadActorPicture` / `uploadActorPictureBulk` | Icons with SVG→PNG. |
| `createForm` / `updateForm` / `getForms` | Form-template lifecycle. |
| `createAccountPair` / `createTransaction` / `createTransfer` | Financial accounts and value movement. |
| `createChart` / `createDashboard` | Visualise account / counter data. |

FOOTER

  echo ""
  echo "✓ Kiro Power built"
  echo "  Output:   $OUTPUT_DIR"
  echo "  Version:  $VERSION (read from .claude-plugin/plugin.json; not modified — versions are minted by 'make release')"
  echo "  Skills → steering files: $skill_count"
  echo ""
  echo "  Structure:"
  echo "    $(basename "$OUTPUT_DIR")/"
  echo "    ├── POWER.md"
  echo "    ├── mcp.json"
  echo "    └── steering/      ($skill_count files, doc refs point at $PLUGIN_ROOT/docs)"
  ls "$OUTPUT_DIR/steering/" | sed 's/^/        /'
  echo ""
  echo "  Install in Kiro: Powers panel → Add Custom Power → Import from folder"
}

# ─── Mode: build + install directly into this machine's local Kiro ─────────

run_install_power() {
  POWER_NAME="power-simulator"
  BUILD_DIR="$REPO_ROOT/power-simulator"
  KIRO_POWERS_DIR="$HOME/.kiro/powers/installed"
  INSTALLED_JSON="$HOME/.kiro/powers/installed.json"
  DEST="$KIRO_POWERS_DIR/$POWER_NAME"

  run_power_build "$BUILD_DIR"

  mkdir -p "$KIRO_POWERS_DIR"
  rm -rf "$DEST"
  cp -R "$BUILD_DIR" "$DEST"

  # jq isn't guaranteed installed; python3 already is (PUBLISHING.md's own
  # manifest checks depend on it), so use it for a JSON-safe merge instead
  # of pattern-matching installed.json with sed.
  python3 - "$INSTALLED_JSON" "$POWER_NAME" << 'PYEOF'
import json
import os
import sys

path, name = sys.argv[1], sys.argv[2]

if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    data = {"version": "1.0.0", "installedPowers": [], "dismissedAutoInstalls": []}

powers = data.setdefault("installedPowers", [])
if not any(p.get("name") == name for p in powers):
    powers.append({"name": name, "registryId": "user-added"})

with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

  # 3) Enable the power's MCP server in ~/.kiro/settings/mcp.json
  #    Key format: power-<power-folder-name>-<server-name-in-mcp.json>
  MCP_CONFIG="$HOME/.kiro/settings/mcp.json"
  POWER_MCP_KEY="power-power-simulator-simulator"

  if [ -f "$MCP_CONFIG" ]; then
    python3 - "$MCP_CONFIG" "$POWER_MCP_KEY" "$DEST/mcp.json" << 'PYEOF'
import json
import sys

mcp_path, power_key, power_mcp_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(mcp_path) as f:
    mcp = json.load(f)

with open(power_mcp_path) as f:
    power_mcp = json.load(f)

# Extract the server config from the power's mcp.json
server_cfg = power_mcp.get("mcpServers", {}).get("simulator", {})
server_cfg.pop("disabled", None)
server_cfg["disabled"] = False

# Ensure powers.mcpServers section exists
mcp.setdefault("powers", {}).setdefault("mcpServers", {})
mcp["powers"]["mcpServers"][power_key] = server_cfg

with open(mcp_path, "w") as f:
    json.dump(mcp, f, indent=2)
    f.write("\n")
PYEOF
    echo "✓ Power MCP server enabled: $POWER_MCP_KEY"
  else
    echo "⚠ $MCP_CONFIG not found — Kiro will generate it on first launch."
    echo "  You may need to manually enable the power's MCP server."
  fi

  echo ""
  echo "✓ Installed simulator Power directly into Kiro"
  echo "  Bundle:     $DEST"
  echo "  Registered: $INSTALLED_JSON"
  echo "  MCP key:    $POWER_MCP_KEY (enabled)"
  echo ""
  echo "  Restart Kiro (or reload window) to pick it up."
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--power" ]; then
  shift
  run_power_build "$@"
else
  # Workspace-install mode always also runs --install-power, so the plugin
  # stays registered as a Kiro Power globally, not just in one workspace.
  # --install-power still works standalone (no workspace-dir) to do just
  # the global install, e.g. `install-kiro.sh --install-power`.
  bare_install_power=0
  workspace_arg=""
  for arg in "$@"; do
    if [ "$arg" = "--install-power" ]; then
      bare_install_power=1
    else
      workspace_arg="$arg"
    fi
  done

  if [ "$bare_install_power" = "1" ] && [ -z "$workspace_arg" ]; then
    run_install_power
  else
    run_workspace_install "$workspace_arg"
    run_install_power
  fi
fi
