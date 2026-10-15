"""Select deployment targets independently of validation jobs."""

import os


def release_targets(event, *, api_changed, agents_changed, request_api, request_agents):
    # A dispatch's diff may describe the previous push; only its explicit choices apply.
    if event == "workflow_dispatch":
        return {"deploy_api": request_api, "deploy_agents": request_agents}
    return {
        "deploy_api": api_changed,
        "deploy_agents": agents_changed,
    }


if __name__ == "__main__":
    targets = release_targets(
        os.environ["RELEASE_EVENT"],
        api_changed=os.environ.get("API_CHANGED") == "true",
        agents_changed=os.environ.get("AGENTS_CHANGED") == "true",
        request_api=os.environ.get("REQUEST_API") == "true",
        request_agents=os.environ.get("REQUEST_AGENTS") == "true",
    )
    for name, selected in targets.items():
        print(f"{name}={str(selected).lower()}")
