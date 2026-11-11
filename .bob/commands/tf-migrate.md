# `/tf-migrate` Slash Command

Perform automated, safe code transformations to migrate this repository's Terraform configuration to Terraform Enterprise.

```prompt
Switch to `tf-migrator` mode and activate the `tf-code-migrate` skill.
Resolve the target first: the TFE hostname, organization and workspace must come from my request, the repository's existing `cloud`/`remote` block, or the `tfctl` profile's `default_organization`. If none names them, report the target as `NOT SPECIFIED`, make no changes (no branch, no backend edit), and ask me to confirm host, organization and workspace. Never guess or pick an organization because it is accessible.
Execute the following migration steps:
1. Ensure working directory is clean and checkout a new migration branch (`migration/tfe-<workspace-name>`).
2. Replace legacy backend blocks with modern `cloud` or `remote` blocks configured for the resolved target TFE instance.
3. Upgrade `required_version` to satisfy TFE requirements (>= 1.1.0) and pin all providers with explicit source namespaces and version constraints.
4. If PMR is in scope, refactor module source addresses.
5. Format and locally validate code changes (`terraform fmt`, `terraform validate`).
6. Generate a Git Pull Request description with a summary of changes and a link to the state migration runbook.
```
