"""Select deployment targets independently of validation jobs."""

import os
from pathlib import Path
import subprocess
import tomllib


def release_targets(event, *, api_changed, agents_changed, request_api, request_agents):
    # A dispatch's diff may describe the previous push; only its explicit choices apply.
    if event == "workflow_dispatch":
        return {"deploy_api": request_api, "deploy_agents": request_agents}
    return {
        "deploy_api": api_changed,
        "deploy_agents": agents_changed,
    }


def api_only_lock_update(base):
    """Keep the normal agent release unless only the standalone API's dependencies changed."""
    if not base or not base.strip("0"):
        return False
    try:
        old = tomllib.loads(subprocess.check_output(["git", "show", base + ":Cargo.lock"],
                                                   text=True, stderr=subprocess.DEVNULL))
        new = tomllib.loads(Path("Cargo.lock").read_text())
        dependencies = []
        for lock in (old, new):
            if set(lock) != {"package", "version"} or lock["version"] != 4:
                return False
            apis = []
            for package in lock["package"]:
                name, version = package["name"], package["version"]
                deps = package.get("dependencies", [])
                if not isinstance(name, str) or not isinstance(version, str) or not isinstance(deps, list):
                    return False
                # A package that depends on pulse-api could be an agent or an agent dependency.
                if any(not isinstance(d, str) or not d.split() or d.split()[0] == "pulse-api" for d in deps):
                    return False
                if name == "pulse-api" and "source" not in package:
                    apis.append(package)
            if len(apis) != 1:
                return False
            dependencies.append(apis[0].pop("dependencies", []))
        return dependencies[0] != dependencies[1] and old == new
    except (OSError, ValueError, TypeError, KeyError, subprocess.CalledProcessError):
        return False


if __name__ == "__main__":
    event = os.environ["RELEASE_EVENT"]
    agent_change = os.environ.get("AGENTS_CHANGED") == "true"
    if event != "workflow_dispatch" and agent_change and os.environ.get("ONLY_AGENT_LOCKFILE") == "true":
        agent_change = not api_only_lock_update(os.environ.get("RELEASE_BASE"))
    targets = release_targets(
        event,
        api_changed=os.environ.get("API_CHANGED") == "true",
        agents_changed=agent_change,
        request_api=os.environ.get("REQUEST_API") == "true",
        request_agents=os.environ.get("REQUEST_AGENTS") == "true",
    )
    for name, selected in targets.items():
        print(f"{name}={str(selected).lower()}")
