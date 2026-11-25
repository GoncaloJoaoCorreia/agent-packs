#!/bin/sh
# Pre-release validation for the open-driver pack (packs/open-driver).
# Used by the root scripts/validate.sh dispatcher (which .github/workflows call);
# also runnable directly: sh packs/open-driver/scripts/validate.sh
# Requires: sh, ruby (with psych/yaml + json stdlib), python3 (agent-scripts/ is a
# shipped payload — CI on ubuntu-latest has it preinstalled). shellcheck is optional
# (skipped if absent).
set -eu
PACK_DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$PACK_DIR/../.." && pwd)
cd "$PACK_DIR"

echo "== install.sh syntax =="
sh -n "$REPO/install.sh"
echo "ok: sh -n install.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$REPO/install.sh"
  echo "ok: shellcheck install.sh"
else
  echo "skip: shellcheck not installed"
fi

echo "== install.sh excludes .agent/ and __pycache__ from the installed payload =="
# regression test: .agent/ dirs and bytecode caches in the payload dirs must never be
# installed — OpenCode discovers agents/**/*.md recursively, so an installed
# .agent/*.md would be registered as an agent (".agent/history" etc.). This repo no
# longer keeps its own .agent/ history (the driver no longer records it), so plant
# synthetic fixtures in two payload dirs to keep this test meaningful.
install_tmp=$(mktemp -d)
trap 'rm -rf "$install_tmp" agents/.agent skills/driver-conventions/.agent' EXIT
mkdir -p agents/.agent skills/driver-conventions/.agent
echo "# synthetic driver history" > agents/.agent/history.md
echo "# synthetic decisions" > skills/driver-conventions/.agent/decisions.md
sh "$REPO/install.sh" --source --dest "$install_tmp/cfg" open-driver >/dev/null
if find "$install_tmp/cfg" -type d \( -name .agent -o -name __pycache__ \) | grep -q .; then
  echo "FAIL: .agent/ or __pycache__/ installed into $install_tmp/cfg:" >&2
  find "$install_tmp/cfg" -type d \( -name .agent -o -name __pycache__ \) >&2
  exit 1
fi
manifest="$install_tmp/cfg/agent-packs.open-driver.manifest"
if grep -Eq '(^|/)(\.agent|__pycache__)/' "$manifest"; then
  echo "FAIL: manifest lists .agent/ or __pycache__ entries:" >&2
  grep -E '(^|/)(\.agent|__pycache__)/' "$manifest" >&2
  exit 1
fi
echo "ok: no .agent/ or __pycache__/ in installed payload or manifest"

echo "== installer installs the full payload (incl. agent-scripts/ + skills/) =="
for f in agents/driver.md plugins/driver-viz/tui.tsx \
         skills/driver-conventions/SKILL.md agent-scripts/driver-state.py \
         agent-packs.open-driver.manifest agent-packs.open-driver.version; do
  [ -e "$install_tmp/cfg/$f" ] || { echo "FAIL: installed cfg is missing $f" >&2; exit 1; }
done
[ -e "$install_tmp/cfg/snippets/gitignore.txt" ] && { echo "FAIL: snippets/ must be ship-only, not installed" >&2; exit 1; }
echo "ok: payload installed (incl. agent-scripts/ + skills/), snippets/ not installed"

echo "== --list shows the pack =="
if ! sh "$REPO/install.sh" --source --list | grep -q 'open-driver'; then
  echo "FAIL: install.sh --list does not list the open-driver pack" >&2
  exit 1
fi
echo "ok: --list lists open-driver"

echo "== asset convention files =="
for f in "$REPO/install.sh" "$REPO/scripts/install-lib.sh" pack.conf install.sh \
         agents commands snippets plugins agent-scripts skills; do
  [ -e "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done
echo "ok: install.sh + install-lib.sh + pack.conf + pack install.sh + agents/ commands/ snippets/ plugins/ agent-scripts/ skills/ present"

echo "== agent-scripts =="
AS="$PACK_DIR/agent-scripts"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required (agent-scripts/driver-state.py) but not found" >&2; exit 1; }
for s in "$AS"/*.sh; do
  sh -n "$s"
done
echo "ok: sh -n agent-scripts/*.sh"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$AS"/*.sh
  echo "ok: shellcheck agent-scripts/*.sh"
else
  echo "skip: shellcheck not installed"
fi
python3 -m py_compile "$AS"/*.py
echo "ok: py_compile agent-scripts/*.py"
sh "$AS/tests/run-tests.sh"

command -v ruby >/dev/null 2>&1 || { echo "FAIL: ruby is required for validation" >&2; exit 1; }

echo "== frontmatter / schemas / cross-references =="
ruby -ryaml -rjson <<'RUBY'
failures = []

md_files = Dir.glob("agents/**/*.md") + Dir.glob("commands/**/*.md") + Dir.glob("skills/driver-conventions/**/SKILL.md")
md_files.each do |f|
  m = File.read(f).match(/\A---\n(.*?)\n---\n/m)
  if m.nil?
    failures << "#{f}: no frontmatter block"
    next
  end
  begin
    YAML.safe_load(m[1], permitted_classes: [Symbol], aliases: true)
  rescue => e
    failures << "#{f}: invalid YAML frontmatter: #{e.message}"
  end
end

Dir.glob("skills/driver-conventions/**/*.json").each do |f|
  begin
    JSON.parse(File.read(f))
  rescue => e
    failures << "#{f}: invalid JSON: #{e.message}"
  end
end

Dir.glob("snippets/*.jsonc").each do |f|
  stripped = File.read(f).gsub(%r{^\s*//.*$}, "").gsub(/,(\s*[}\]])/, '\1')
  begin
    JSON.parse(stripped)
  rescue => e
    failures << "#{f}: invalid JSONC: #{e.message}"
  end
end

# cross-ref: every command's \`agent:\` must resolve to an agent file agents/<id>.md
Dir.glob("commands/**/*.md").each do |f|
  m = File.read(f).match(/\A---\n(.*?)\n---\n/m)
  next if m.nil?
  data = YAML.safe_load(m[1], permitted_classes: [Symbol], aliases: true) || {}
  agent = data["agent"]
  next if agent.nil? || agent.to_s.empty?
  path = "agents/#{agent}.md"
  failures << "#{f}: agent '#{agent}' has no file #{path}" unless File.exist?(path)
end

# coverage: every real phase agent (non-symlink) in agents/driver/ needs a
# commands/phases/<name>.md wrapper and a row in the driver registry
driver_md = File.read("agents/driver.md")
Dir.glob("agents/driver/*.md").each do |f|
  next if File.symlink?(f) # placeholder variants (e.g. plan-thorough) are exempt
  name = File.basename(f, ".md")
  failures << "no standalone command commands/phases/#{name}.md for agent driver/#{name}" unless File.exist?("commands/phases/#{name}.md")
  failures << "agents/driver.md registry does not mention driver/#{name}" unless driver_md.include?("driver/#{name}")
end

# content invariants across agents/ + the conventions skill
SLUG_RE = '^[A-Z][A-Z0-9]*-[0-9]+$'
content_files = Dir.glob("agents/**/*.md") + Dir.glob("skills/driver-conventions/**/*.md")
content_files.each do |f|
  src = File.read(f)
  # invariant 1: every phase loads the conventions skill
  if f.start_with?("agents/driver") && !src.include?("driver-conventions")
    failures << "#{f}: does not reference the driver-conventions skill"
  end
  # invariant 2: any file that builds .plan/ paths must carry the slug regex
  if src.include?(".plan/<") && !src.include?(SLUG_RE)
    failures << "#{f}: uses .plan/<slug> paths but does not state the slug regex #{SLUG_RE}"
  end
end

# invariant 3: every phase denies \`git push *\` except pr.md (which must not deny it)
Dir.glob("agents/driver/*.md").each do |f|
  next if File.symlink?(f)
  src = File.read(f)
  push_deny = src.include?('"git push *"') && src.match?(/git push \*.*deny|deny.*git push \*/m)
  if File.basename(f) == "pr.md"
    failures << "#{f}: pr.md must NOT deny 'git push *' (it is the only phase allowed to push)" if push_deny
  else
    failures << "#{f}: missing deny rule for 'git push *'" unless push_deny
  end
end

# invariant 4: the Linear MCP permission block is identical in preplan.md and plan.md
linear_lines = lambda do |f|
  File.readlines(f).select { |l| l =~ /linear[-_]project/ && l.strip.start_with?("- {") }
end
preplan_lin = linear_lines.call("agents/driver/preplan.md")
plan_lin = linear_lines.call("agents/driver/plan.md")
if preplan_lin.empty? || plan_lin.empty? || preplan_lin != plan_lin
  failures << "agents/driver/preplan.md and agents/driver/plan.md: linear-project permission blocks differ (or missing) — keep them byte-identical"
end

# invariant 5: the shipped driver-state.py carries the slug regex (its .plan/<slug>
# path guard validates slugs against it)
unless File.read("agent-scripts/driver-state.py").include?(SLUG_RE)
  failures << "agent-scripts/driver-state.py: missing slug regex #{SLUG_RE}"
end

if failures.empty?
  puts "ok: #{md_files.size} markdown files, schemas, cross-references all valid"
else
  failures.each { |f| $stderr.puts "FAIL: #{f}" }
  exit 1
end
RUBY

echo "== all validations passed =="
