"""Prepare the worktree a delivery run works in, before the workflow starts.

prepare-delivery.sh runs this from the invoking session. It does with fixed
commands what the workflow's setup and branch agents used to relay: find or cut
the ticket's branch and worktree, read the gate markers, the plugin's own
version, the base branch's manifest, and the AGENTS.md (or CLAUDE.md) sections
the workflow parses its checks from. It prints one JSON object and exits 0, or
prints {"error", "reason"} and exits 2 (bad arguments, setup problem) or 3 (a
refusal: nothing to deliver into, or something in the way).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import NamedTuple

TYPES = ("feat", "fix", "chore", "refactor", "docs", "test", "perf", "build", "ci")
GH = "gh"
SHA = re.compile(r"[0-9a-f]{40}")
SLUG = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+){0,5}")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
OTHER_MARKER = re.compile(r"(gh-[0-9]+|jira-[A-Za-z][A-Za-z0-9]*-[0-9]+)-")
PRIOR_HEAD = "TOUCHSTONE_PRIOR_HEAD_LINEAR"


class Run(NamedTuple):
    code: int
    out: str
    err: str


class Refusal(Exception):
    def __init__(self, error, reason, code=3):
        self.error, self.reason, self.code = error, reason, code


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("bad-args", message, 2)


def _run(argv, cwd=None):
    # The invoking session has no terminal to answer a credential prompt on, so a
    # prompt must fail instead of hanging the session.
    return subprocess.run(argv, cwd=cwd, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                          env={**os.environ, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1"})


def git(root, *args):
    done = _run(["git", "-C", root, *args])
    return Run(done.returncode, done.stdout, done.stderr)


def marker_for(ref):
    t = str(ref).strip()
    t = t[1:] if t.startswith("#") else t
    if re.fullmatch(r"[0-9]+", t):
        return f"gh-{t}"
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-[0-9]+", t):
        return f"jira-{t.upper()}"
    return None


def parse(argv):
    p = _Parser()
    p.add_argument("repo")
    p.add_argument("--ticket", required=True)
    p.add_argument("--type", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--existing", action="store_true")
    p.add_argument("--base")
    p.add_argument("--prior-head")
    p.add_argument("--plugin-json", required=True)
    return p.parse_args(argv)


def _bad(reason):
    raise Refusal("bad-args", reason, 2)


def validate(opts):
    """The ticket marker, once every argument is known to be usable."""
    marker = marker_for(opts.ticket)
    for ok, reason in (
        (os.path.isabs(opts.repo), f"repo path must be absolute, got {opts.repo!r}"),
        (marker, f"ticket {opts.ticket!r} is neither a GitHub issue number nor a Jira key"),
        (opts.type in TYPES, f"--type must be one of {', '.join(TYPES)}, got {opts.type!r}"),
        (SLUG.fullmatch(opts.slug),
         f"--slug must be lowercase words joined by single hyphens, at most 6, got {opts.slug!r}"),
        (_base_ok(opts.base), f"--base is not a ref name: {opts.base!r}"),
    ):
        if not ok:
            _bad(reason)
    _validate_prior_head(opts)
    return marker


def _base_ok(base):
    return base is None or (bool(base) and not base.startswith("-"))


def _validate_prior_head(opts):
    if opts.prior_head is None:
        return
    if not opts.existing:
        _bad("--prior-head is only meaningful with --existing")
    if not SHA.fullmatch(opts.prior_head):
        _bad(f"--prior-head must be a 40-character SHA, got {opts.prior_head!r}")


def plugin_of(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as error:
        raise Refusal("plugin-unreadable", f"cannot read {path}: {error}", 2)
    if not _is_manifest(data):
        raise Refusal("plugin-unreadable", f"{path} has no string name and version", 2)
    return {"name": data["name"], "version": data["version"]}


def _is_manifest(data):
    return isinstance(data, dict) and isinstance(data.get("name"), str) \
        and isinstance(data.get("version"), str)


def repo_root(path):
    """The main checkout: a linked worktree's own toplevel would nest new worktrees inside it."""
    r = git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if r.code:
        _bad(f"not a git repository: {path}")
    return os.path.dirname(r.out.strip())


def _ref_exists(root, ref):
    return git(root, "cat-file", "-e", ref).code == 0


def default_base(root):
    named = git(root, "for-each-ref", "--format=%(symref:short)", "refs/remotes/origin/HEAD").out.strip()
    if named:
        return named.removeprefix("origin/")
    for name in ("main", "master"):
        if _ref_exists(root, f"refs/heads/{name}") or _ref_exists(root, f"refs/remotes/origin/{name}"):
            return name
    return None


def base_manifest(root, base, refreshed):
    empty = {"found": False, "refreshed": refreshed, "name": "", "version": ""}
    if not base:
        return {**empty, "detail": "no base branch resolved"}
    source = f"origin/{base}:.claude-plugin/plugin.json"
    r = git(root, "show", source)
    data = _json_or_none(r.out)
    if not _is_manifest(data):
        return {**empty, "detail": f"no usable manifest at {source}"}
    stale = "" if refreshed else "; the fetch failed, so the ref may be stale"
    return {**empty, "found": True, "name": data["name"], "version": data["version"],
            "detail": f"read {source}{stale}"}


def _json_or_none(text):
    try:
        return json.loads(text)
    except ValueError:
        return None


def markers(root):
    return {"crap_gated": os.path.isfile(os.path.join(root, ".crap-gated")),
            "mutation_gated": os.path.isfile(os.path.join(root, ".mutation-gated"))}


def canonical(root, name):
    return os.path.join(root, ".claude", "worktrees", name)


def carries(branch, marker):
    return branch.partition("/")[2].startswith(f"{marker}-")


def _cut_point(root, given, default, refreshed):
    if given:
        if git(root, "cat-file", "-e", f"{given}^{{commit}}").code:
            raise Refusal("base-unresolved", f"the given base {given} does not resolve to a commit")
        return given
    if not default:
        raise Refusal("base-unresolved", "no base branch: origin/HEAD is unset and neither main nor master exists")
    if not refreshed:
        raise Refusal("fetch-failed", f"git fetch origin {default} failed; not cutting from a stale base")
    return f"origin/{default}"


def _refuse_taken_name(root, branch):
    if _ref_exists(root, f"refs/heads/{branch}"):
        raise Refusal("local-branch-exists",
                      f"branch {branch} already exists locally; pass --existing to continue it")
    r = git(root, "ls-remote", "origin", f"refs/heads/{branch}")
    if r.code:
        raise Refusal("remote-check-failed",
                      f"git ls-remote origin refs/heads/{branch} failed: {r.err.strip()}")
    if r.out.strip():
        raise Refusal("remote-branch-exists",
                      f"branch {branch} already exists on origin; its pull request belongs to "
                      f"that branch, so pick another slug or pass --existing to continue it")


def _add_worktree(root, path, *args):
    r = git(root, "worktree", "add", path, *args)
    if r.code:
        raise Refusal("worktree-add-failed", f"git worktree add {path} failed: {r.err.strip()}")


def fresh(root, opts, marker, default, refreshed):
    branch = f"{opts.type}/{marker}-{opts.slug}"
    cut = _cut_point(root, opts.base, default, refreshed)
    _refuse_taken_name(root, branch)
    path = canonical(root, f"{marker}-{opts.slug}")
    if os.path.lexists(path):
        raise Refusal("path-occupied", f"{path} already exists; not deleting or renaming around it")
    _add_worktree(root, path, "-b", branch, cut)
    return {"worktree": path, "branch": branch, "base": opts.base or default,
            "worktree_action": "created", "detail": f"cut {branch} from {cut}"}


def worktree_records(root):
    records, path = [], None
    for line in git(root, "worktree", "list", "--porcelain").out.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/"):
            records.append((path, line[len("branch refs/heads/"):]))
    return records


def local_branches(root):
    return git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads/").out.split()


def _one(found, marker, what):
    if len(found) > 1:
        raise Refusal("ambiguous", f"more than one {what} carries the {marker} marker: "
                      + ", ".join(str(f) for f in found))
    return found[0] if found else None


def latest_pr(text):
    """The open PR if there is one, else the highest-numbered, as the draft-PR step picks."""
    prs = sorted(_prs(_json_or_none(text)), key=lambda d: -d["number"])
    return next((d for d in prs if d["state"] == "OPEN"), prs[0] if prs else None)


def _prs(data):
    return [d for d in data if _is_pr(d)] if isinstance(data, list) else []


def _is_pr(d):
    return isinstance(d, dict) and isinstance(d.get("number"), int) and isinstance(d.get("state"), str)


def _merged_check(root, branch):
    """Refuses a branch whose latest PR merged; otherwise a note for detail, '' when gh answered."""
    try:
        done = _run([GH, "pr", "list", "--head", branch, "--state", "all", "--json", "number,state",
                     "--limit", "20"], cwd=root)
    except OSError as error:
        return f"; merged check skipped: could not run {GH}: {error}"
    if done.returncode:
        return f"; merged check skipped: gh exited {done.returncode}"
    pr = latest_pr(done.stdout)
    if pr and pr["state"] == "MERGED":
        raise Refusal("merged", f"branch {branch}'s latest pull request (#{pr['number']}) merged; "
                      f"that work shipped, so it is not a tree to keep implementing into")
    return ""


def _refuse_dirty(path):
    r = git(path, "status", "--porcelain")
    if r.code or r.out.strip():
        raise Refusal("dirty", f"{path} has uncommitted changes, which a later git add -A would "
                      f"sweep into a commit: {(r.out + r.err).strip()}")


def _adopt(here, marker, bases):
    """The checkout's own branch, when nothing carries the marker: a branch older than the convention."""
    current = git(here, "branch", "--show-current").out.strip()
    other = OTHER_MARKER.match(current.partition("/")[2])
    if other:
        raise Refusal("wrong-ticket", f"no worktree or branch carries {marker}, and the checkout is on "
                      f"{current}, which belongs to {other.group(1)}")
    if not current or current in bases:
        raise Refusal("not-found", f"no worktree or branch carries the {marker} marker, and the checkout "
                      f"is not on a feature branch; run without --existing to cut one")
    return git(here, "rev-parse", "--show-toplevel").out.strip(), current, "adopted", ""


def _reattach(root, here, marker, bases):
    branch = _one([b for b in local_branches(root) if carries(b, marker)], marker, "branch")
    if branch is None:
        return _adopt(here, marker, bases)
    note = _merged_check(root, branch)
    path = canonical(root, branch.partition("/")[2].replace("/", "-"))
    if os.path.lexists(path):
        raise Refusal("occupied", f"branch {branch} has no worktree, but {path} is already occupied")
    _add_worktree(root, path, branch)
    return path, branch, "reattached", note


def existing(root, opts, marker, default):
    base = opts.base or default
    if not base:
        raise Refusal("base-unresolved", "no base branch: origin/HEAD is unset and neither main nor master exists")
    hit = _one([r for r in worktree_records(root) if carries(r[1], marker)], marker, "worktree")
    if hit:
        path, branch, action, note = (*hit, "reused", _merged_check(root, hit[1]))
    else:
        bases = {base, default, "main", "master"}
        path, branch, action, note = _reattach(root, opts.repo, marker, bases)
    _refuse_dirty(path)
    return {"worktree": path, "branch": branch, "base": base, "worktree_action": action,
            "detail": f"{action} the worktree of {branch}{note}"}


def _fence_closes(line, fence):
    return re.fullmatch(f" {{0,3}}{re.escape(fence[:1])}{{{len(fence)},}}[ \t]*", line) is not None


def sections_of(text):
    """Every "##" line outside a fence, with the first fence before the next one, verbatim."""
    sections, state = [], {"fence": None, "capture": None}
    for line in text.splitlines():
        _take(line, sections, state)
    _flush(sections, state["capture"])
    return sections


def _take(line, sections, state):
    if state["fence"]:
        _inside_fence(line, sections, state)
        return
    opened = FENCE.match(line)
    if opened:
        state["fence"] = opened.group(1)
        state["capture"] = [line] if sections and not sections[-1]["fence"] else None
    elif line.startswith("##"):
        sections.append({"heading": line, "fence": ""})


def _inside_fence(line, sections, state):
    if state["capture"] is not None:
        state["capture"].append(line)
    if _fence_closes(line, state["fence"]):
        state["fence"], state["capture"] = None, _flush(sections, state["capture"])


def _flush(sections, capture):
    if capture is not None:
        sections[-1]["fence"] = "\n".join(capture)
    return None


def checks_source(path):
    for name in ("AGENTS.md", "CLAUDE.md"):
        file = os.path.join(path, name)
        if os.path.isfile(file):
            with open(file) as f:
                sections = sections_of(f.read())
            return {"file": file, "sections": sections, "detail": f"read {file}: {len(sections)} sections"}
    return {"file": "", "sections": [], "detail": "neither AGENTS.md nor CLAUDE.md exists"}


def prior_head_check(path, sha):
    if git(path, "merge-base", "--is-ancestor", sha, "@").code:
        return f"{PRIOR_HEAD} 1"
    merges = git(path, "rev-list", "--merges", f"{sha}..@").out.strip()
    return f"{PRIOR_HEAD} {2 if merges else 0}"


def prepare(opts):
    marker = validate(opts)
    plugin = plugin_of(opts.plugin_json)
    root = repo_root(opts.repo)
    git(root, "worktree", "prune")
    default = default_base(root)
    refreshed = bool(default) and git(root, "fetch", "origin", default).code == 0
    place = existing(root, opts, marker, default) if opts.existing \
        else fresh(root, opts, marker, default, refreshed)
    head = opts.prior_head
    return {"repo_root": root, **place, "ticket": opts.ticket, "ticket_marker": marker,
            "mode": "existing" if opts.existing else "fresh", "markers": markers(root),
            "plugin": plugin, "base_manifest": base_manifest(root, default, refreshed),
            "checks_source": checks_source(place["worktree"]), "prior_head": head,
            "prior_head_check": prior_head_check(place["worktree"], head) if head else None}


def main(argv):
    try:
        result = prepare(parse(argv))
    except Refusal as refusal:
        print(json.dumps({"error": refusal.error, "reason": refusal.reason}))
        return refusal.code
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
