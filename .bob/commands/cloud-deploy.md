---
name: cloud-deploy
description: '# `/cloud-deploy` Slash Command'
metadata:
  user-invocable: true
  disable-model-invocation: true
---

# `/cloud-deploy` Slash Command

Provision or validate target Terraform Enterprise (TFE) landing zone resources (Workspace, Project, Variable Sets) via `tfctl` before state migration.

```prompt
Switch to `tf-migrator` mode and activate the `cloud-deploy` skill.
Target TFE host, organization and workspace: use only what the user supplied. If none was supplied, report the target as `NOT SPECIFIED` and ask for confirmation.
1. Run `tfctl create workspace -a name=<workspace-name> -o <org-name> --dry-run` to preview workspace creation.
2. Check for existing workspace collisions using `tfctl get workspaces -o <org-name>`.
3. Provide tfctl commands or payload specifications for workspace creation and variable set attachment.
```
