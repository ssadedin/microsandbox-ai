"""
Shared pieces of the GitLab bridge: configuration, the API client and
the hardened git helpers.

Everything the sandbox can write (the checkout, .git/config, hooks, the
.git file of a submodule) is untrusted from the host's point of view, so
git is only ever run here with hooks, fsmonitor, credential helpers and
the user's global config switched off, and analysis of what an agent
committed is done in a scratch repository that borrows the checkout's
objects (objects/info/alternates) and so never reads its config.
"""

import atexit
import base64
import contextlib
import fnmatch
import json
import os
import re
import shutil
import ssl
import stat
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_CONFIG = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "msb-agent", "gitlab.json")

STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "msb-agent", "gitlab")

PROJECT_RE = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$")
BRANCH_RE = re.compile(r"^[A-Za-z0-9._][A-Za-z0-9._/-]{0,199}$")
HASH_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
REPO_PATH_RE = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")

# Protocol git may use for fetching and pushing. Only changed by tests.
GIT_PROTOCOL = "https"

GITLINK_MODE = "160000"


class BridgeError(Exception):
    """An error whose message is safe to show the agent."""


def valid_branch(name):
    return bool(BRANCH_RE.match(name)) and ".." not in name \
        and not name.endswith((".lock", "/", ".")) and "//" not in name


def valid_repo_path(path):
    return path == "." or (bool(REPO_PATH_RE.match(path))
                           and not any(p in (".", "..") for p in path.split("/")))


# ----------------------------------------------------------------
# Configuration (host side, trusted)
# ----------------------------------------------------------------

def load_config(path):
    try:
        with open(path) as f:
            cfg = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise BridgeError(f"cannot read {path}: {e}")
    if not isinstance(cfg, dict):
        raise BridgeError(f"{path}: expected a JSON object")
    return cfg


def _is_path_key(key):
    return key.startswith(("/", "~", ".")) or "$" in key


def repo_config(cfg, *checkouts):
    """The "repos" entry keyed by one of the given checkout paths.

    A key is a path if it starts with /, ~ or . or contains $VARS; "~" and
    environment variables are expanded. Other keys are project paths, see
    project_config.
    """
    wanted = {os.path.realpath(c) for c in checkouts if c}
    for key, val in (cfg.get("repos") or {}).items():
        if _is_path_key(key) and os.path.realpath(
                os.path.expandvars(os.path.expanduser(key))) in wanted:
            return val or {}
    return {}


def project_config(cfg, project):
    """The "repos" entry keyed by a project path or glob matching this project.

    Project keys name the project the checkout's origin remote points at (for
    example "group/app" or "group/*"), so one config works on every machine.
    An exact key beats a glob; otherwise the first match in the file wins.
    """
    if not project:
        return {}
    matches = [(key, val) for key, val in (cfg.get("repos") or {}).items()
               if not _is_path_key(key) and fnmatch.fnmatchcase(project, key)]
    for key, val in matches:
        if key == project:
            return val or {}
    return (matches[0][1] or {}) if matches else {}


def parse_remote(url):
    """Return (host, path) from an ssh, scp-like or http(s) remote URL."""
    url = url.strip()
    m = re.match(r"^(?:[\w.-]+@)?([\w.-]+):(?!//)(.+)$", url)
    if m and "://" not in url:
        host, path = m.group(1), m.group(2)
    else:
        u = urllib.parse.urlparse(url)
        host, path = u.hostname, u.path
    if not host:
        raise BridgeError(f"cannot parse remote URL {url!r}")
    path = path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    return host.lower(), path


def resolve_relative_url(parent_url, rel):
    """Resolve a submodule URL like ../x.git against its superproject's URL."""
    if not rel.startswith(("./", "../")):
        return rel
    m = re.match(r"^((?:[\w.-]+@)?[\w.-]+:)(?!//)(.+)$", parent_url)
    if m and "://" not in parent_url:
        head, path = m.group(1), m.group(2)
    else:
        u = urllib.parse.urlparse(parent_url)
        head, path = f"{u.scheme}://{u.netloc}/", u.path.lstrip("/")
    segments = [s for s in path.split("/") if s]
    for part in rel.split("/"):
        if part == "..":
            if segments:
                segments.pop()
        elif part not in ("", "."):
            segments.append(part)
    return head + "/".join(segments)


def find_instance(cfg, host):
    """The key of the configured instance serving this host, or None."""
    for key, inst in (cfg.get("instances") or {}).items():
        base = (inst or {}).get("url") or f"https://{key}"
        if host.lower() in (key.lower(), (urllib.parse.urlparse(base).hostname or "").lower()):
            return key
    return None


def parse_issue(spec):
    """Return (project or None, iid) from 32, #32, group/proj#32 or an issue URL."""
    spec = spec.strip()
    m = re.search(r"^(?:https?://[^/]+/)(.+?)/-/issues/(\d+)", spec)
    if m:
        return m.group(1), int(m.group(2))
    m = re.match(r"^(?:([A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)+))?#?(\d+)$", spec)
    if not m or (m.group(1) and "#" not in spec):
        raise BridgeError(f"cannot parse issue {spec!r} (use 32, group/project#32 or an issue URL)")
    return m.group(1), int(m.group(2))


def slugify(text, limit=60):
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    if len(slug) > limit:
        slug = slug[:limit].rsplit("-", 1)[0] if "-" in slug[:limit] else slug[:limit]
    return slug.strip("-")


class Instance:
    """A configured GitLab instance, including its token."""

    def __init__(self, cfg, key):
        inst = (cfg.get("instances") or {}).get(key)
        if inst is None:
            raise BridgeError(f"unknown GitLab instance {key!r}")
        self.key = key
        self.base = (inst.get("url") or f"https://{key}").rstrip("/")
        self.host = (urllib.parse.urlparse(self.base).hostname or key).lower()
        self.ca_file = os.path.expanduser(inst["ca_file"]) if inst.get("ca_file") else None
        self.token = self._read_token(key, inst)

    @staticmethod
    def _read_token(key, inst):
        if inst.get("token_env"):
            token = os.environ.get(inst["token_env"], "")
        elif inst.get("token_file"):
            path = os.path.expanduser(inst["token_file"])
            try:
                if os.stat(path).st_mode & 0o077:
                    raise BridgeError(f"{path} must not be readable by group/others (chmod 600)")
                with open(path) as f:
                    token = f.read()
            except OSError as e:
                raise BridgeError(f"cannot read token file {path}: {e}")
        elif inst.get("token_keychain"):
            try:
                token = subprocess.run(
                    ["security", "find-generic-password", "-s", inst["token_keychain"],
                     "-a", os.environ.get("USER", ""), "-w"],
                    capture_output=True, text=True, check=True).stdout
            except (OSError, subprocess.CalledProcessError):
                raise BridgeError(f"no Keychain item {inst['token_keychain']!r} for instance {key}")
        else:
            raise BridgeError(f"instance {key} needs token_file, token_env or token_keychain")
        token = token.strip()
        if not token:
            raise BridgeError(f"empty token for instance {key}")
        return token

    def matches_host(self, host):
        return host.lower() in (self.key.lower(), self.host)

    def project_from_remote(self, url):
        """The project path for a remote URL on this instance."""
        host, path = parse_remote(url)
        if not self.matches_host(host):
            raise BridgeError(f"{url} is not on GitLab instance {self.key}")
        prefix = urllib.parse.urlparse(self.base).path.strip("/")
        if prefix and path.startswith(prefix + "/") and "://" in url:
            path = path[len(prefix) + 1:]
        if not PROJECT_RE.match(path):
            raise BridgeError(f"bad project path {path!r} in {url}")
        return path

    def repo_url(self, project):
        return f"{self.base}/{project}.git"

    def scrub(self, text):
        auth = base64.b64encode(f"oauth2:{self.token}".encode()).decode()
        return text.replace(self.token, "***").replace(auth, "***")

    def git_net_env(self):
        """Environment giving git the token, for this instance's URLs only."""
        auth = base64.b64encode(f"oauth2:{self.token}".encode()).decode()
        env = {
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": f"http.{self.base}/.extraHeader",
            "GIT_CONFIG_VALUE_0": f"Authorization: Basic {auth}",
        }
        if self.ca_file:
            env["GIT_SSL_CAINFO"] = self.ca_file
        return env


# ----------------------------------------------------------------
# GitLab API client
# ----------------------------------------------------------------

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow redirects: the token must not leave the configured host."""

    def redirect_request(self, *a, **k):
        return None


class GitLab:
    def __init__(self, instance):
        self.inst = instance
        ctx = ssl.create_default_context(cafile=instance.ca_file)
        self.opener = urllib.request.build_opener(
            _NoRedirect, urllib.request.HTTPSHandler(context=ctx))
        self._projects = {}
        self._me = None

    def call(self, method, path, params=None, body=None):
        url = f"{self.inst.base}/api/v4{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "PRIVATE-TOKEN": self.inst.token, "Content-Type": "application/json",
            "User-Agent": "msb-agent-gitlab-bridge"})
        try:
            with self.opener.open(req, timeout=30) as resp:
                return json.loads(resp.read().decode("utf-8", "replace") or "null")
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                msg = json.loads(e.read().decode("utf-8", "replace"))
                detail = msg.get("message") or msg.get("error") or ""
                if not isinstance(detail, str):
                    detail = json.dumps(detail)
            except ValueError:
                pass
            raise BridgeError(f"GitLab {method} {path.split('?')[0]} failed: "
                              f"HTTP {e.code} {detail[:300]}".strip())
        except (urllib.error.URLError, OSError, ValueError) as e:
            raise BridgeError(f"cannot reach GitLab: {getattr(e, 'reason', e)}")

    @staticmethod
    def project_path(project):
        return "/projects/" + urllib.parse.quote(project, safe="")

    def project(self, project):
        if project not in self._projects:
            self._projects[project] = self.call("GET", self.project_path(project))
        return self._projects[project]

    def default_branch(self, project):
        branch = self.project(project).get("default_branch")
        if not branch:
            raise BridgeError(f"{project} has no default branch (is it empty?)")
        return branch

    def me(self):
        if self._me is None:
            self._me = self.call("GET", "/user")
        return self._me


# ----------------------------------------------------------------
# Hardened git
# ----------------------------------------------------------------

_home = None

# The user's network settings for git: which CA bundle to trust, and any
# corporate proxy. (Never GIT_SSL_NO_VERIFY or the like.)
_NET_ENV = ("GIT_SSL_CAINFO", "SSL_CERT_FILE", "SSL_CERT_DIR",
            "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy",
            "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy")


def _git_env(extra=None):
    global _home
    if _home is None:
        _home = tempfile.mkdtemp(prefix="msb-gitlab-home-")
        atexit.register(shutil.rmtree, _home, True)
    env = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": _home,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    }
    # These only say which certificates to trust and how to reach the
    # network (for example behind a TLS-intercepting corporate proxy).
    for name in _NET_ENV:
        if name in os.environ:
            env[name] = os.environ[name]
    env.update(extra or {})
    return env


_SAFE_CONFIG = [
    "-c", "core.hooksPath=" + os.devnull,
    "-c", "core.fsmonitor=false",
    "-c", "gc.auto=0",
    "-c", "maintenance.auto=false",
    "-c", "credential.helper=",
]


def git(args, cwd=None, env=None, timeout=120, secrets=None):
    """Run git with the safe settings. Returns (returncode, stdout, stderr)."""
    cmd = ["git"] + _SAFE_CONFIG + list(args)
    try:
        r = subprocess.run(cmd, cwd=cwd, env=_git_env(env), capture_output=True,
                           text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise BridgeError(f"git {args[0]} timed out")
    out, err = r.stdout, r.stderr
    if secrets is not None:
        out, err = secrets.scrub(out), secrets.scrub(err)
    return r.returncode, out, err


def git_net_args():
    """Only allow the configured transport (the repo's own config can't widen it)."""
    return ["-c", "protocol.allow=never", "-c", f"protocol.{GIT_PROTOCOL}.allow=always"]


# Repo-local settings that make git run commands or redirect traffic.
_DANGEROUS_KEY = re.compile(
    r"^(filter\..*\.(clean|smudge|process)"
    r"|core\.(fsmonitor|sshcommand|gitproxy|editor|pager|askpass|hookspath|alternaterefscommand)"
    r"|diff\..*\.(command|textconv)|merge\..*\.(driver|recursive)"
    r"|credential\..*|url\..*|include\.path|includeif\..*"
    r"|remote\..*\.(receivepack|uploadpack|proxy|vcs)"
    r"|(uploadpack|receive)\..*|sequence\.editor|pager\..*|gpg\..*program)$")


def audit_config(gitdir, common):
    """Names of repo-local settings that would run commands under our git calls."""
    bad = set()
    for path in {os.path.join(common, "config"), os.path.join(gitdir, "config"),
                 os.path.join(gitdir, "config.worktree")}:
        if not os.path.isfile(path):
            continue
        rc, out, _ = git(["config", "--file", path, "--list", "--name-only", "-z"])
        if rc:
            bad.add(f"unreadable config {os.path.basename(path)}")
            continue
        for key in out.split("\0"):
            if key and _DANGEROUS_KEY.match(key.lower()):
                bad.add(key)
    return sorted(bad)


# ----------------------------------------------------------------
# Reading repository state without running git in the checkout
# ----------------------------------------------------------------

def read_ref(common, ref):
    """The commit a ref points to (loose or packed), or None."""
    path = os.path.join(common, ref)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            if stat.S_ISREG(os.fstat(fd).st_mode):
                text = os.read(fd, 256).decode("ascii", "replace").strip()
                if HASH_RE.match(text):
                    return text
        finally:
            os.close(fd)
    except OSError:
        pass
    try:
        with open(os.path.join(common, "packed-refs")) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2 and parts[1] == ref and HASH_RE.match(parts[0]):
                    return parts[0]
    except OSError:
        pass
    return None


def read_head(gitdir):
    """("branch", name) or ("detached", sha) for a git dir's HEAD."""
    try:
        with open(os.path.join(gitdir, "HEAD")) as f:
            head = f.read().strip()
    except OSError as e:
        raise BridgeError(f"cannot read HEAD of {gitdir}: {e}")
    if head.startswith("ref: refs/heads/"):
        name = head[len("ref: refs/heads/"):]
        if not valid_branch(name):
            raise BridgeError(f"unsupported branch name {name!r}")
        return "branch", name
    if HASH_RE.match(head):
        return "detached", head
    raise BridgeError(f"unsupported HEAD {head[:40]!r}")


def default_ref(common, default):
    """Our best local view of a project's default branch: (ref, sha) or (None, None)."""
    for ref in (f"refs/remotes/origin/{default}", f"refs/heads/{default}"):
        sha = read_ref(common, ref)
        if sha:
            return ref, sha
    return None, None


@contextlib.contextmanager
def scratch_repo(common, refs):
    """A temporary bare repo that can see the checkout's objects and the given refs."""
    objects = os.path.join(common, "objects")
    if not os.path.isdir(objects):
        raise BridgeError("cannot find the repository's object store")
    with tempfile.TemporaryDirectory(prefix="msb-gitlab-scratch-") as tmp:
        repo = os.path.join(tmp, "scratch.git")
        rc, _, err = git(["init", "--bare", "--quiet", repo], cwd=tmp)
        if rc:
            raise BridgeError(f"could not prepare git: {err.strip()[:300]}")
        os.makedirs(os.path.join(repo, "objects", "info"), exist_ok=True)
        with open(os.path.join(repo, "objects", "info", "alternates"), "w") as f:
            f.write(objects + "\n")
        for ref, sha in refs.items():
            if not (ref.startswith("refs/") and HASH_RE.match(sha)):
                raise BridgeError("bad ref for scratch repo")
            rc, _, err = git(["--git-dir", repo, "update-ref", ref, sha], cwd=tmp)
            if rc:
                raise BridgeError(f"commit {sha[:12]} is missing from the object store")
        yield repo


def analyse_branch(common, branch, default):
    """Compare refs/heads/<branch> with the default branch.

    Returns None when the branch doesn't exist, else a dict with tip, base
    (merge base), ahead (commits beyond the default branch) and pointers
    (submodule pointer paths changed between base and tip).
    """
    tip = read_ref(common, f"refs/heads/{branch}")
    if not tip:
        return None
    dref, dsha = default_ref(common, default)
    if not dsha:
        raise BridgeError(f"cannot find the default branch {default} in this repository")
    with scratch_repo(common, {f"refs/heads/{branch}": tip, dref: dsha}) as repo:
        g = ["--git-dir", repo]
        rc, out, err = git(g + ["merge-base", tip, dsha])
        if rc or not out.strip():
            raise BridgeError(f"{branch} shares no history with {default}")
        base = out.split()[0]
        rc, out, err = git(g + ["rev-list", "--count", f"{base}..{tip}"])
        ahead = int(out.strip() or 0) if not rc else 0
        pointers = []
        if ahead:
            rc, out, err = git(g + ["diff-tree", "-r", "--raw", "--no-renames", "-z", base, tip])
            if rc:
                raise BridgeError(f"could not inspect {branch}: {err.strip()[:200]}")
            fields = out.split("\0")
            # ":oldmode newmode oldsha newsha status" NUL path NUL ...
            for meta, path in zip(fields[0::2], fields[1::2]):
                modes = meta.lstrip(":").split()[:2]
                if GITLINK_MODE in modes:
                    pointers.append(path)
    return {"tip": tip, "base": base, "ahead": ahead, "pointers": pointers}


def ahead_of_origin(common, default):
    """Commits on the local default branch that origin/<default> lacks (0 if unknown)."""
    local = read_ref(common, f"refs/heads/{default}")
    remote = read_ref(common, f"refs/remotes/origin/{default}")
    if not local or not remote or local == remote:
        return 0
    with scratch_repo(common, {"refs/heads/l": local, "refs/heads/r": remote}) as repo:
        rc, out, _ = git(["--git-dir", repo, "rev-list", "--count", f"{remote}..{local}"])
    return int(out.strip() or 0) if not rc else 0
