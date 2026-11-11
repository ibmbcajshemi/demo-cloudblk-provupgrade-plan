# `/tf-inventory` Slash Command

Run a read-only estate inventory and pre-migration assessment for this Terraform repository.

```prompt
Activate the `tf-inventory` skill.
Target TFE host, organization and workspace: use only what the user supplied. If none was supplied, treat the target as NOT SPECIFIED. Do not select an organization yourself and do not run workspace-collision checks.
Scan this repository to identify:
1. Current backend type and configuration attributes.
2. Terraform core required_version and provider version constraints.
3. Module dependencies (local, public registry, Git, PMR).
4. Input variables, .tfvars sources, and sensitive variables.
5. Live TFE alignment using `tfctl` (if available in environment) or static heuristics.

Output the complete findings in the standardized Markdown report format and save a copy to `reports/inventory-<repo_slug>-<YYYYMMDD-HHMMSS>.md`.
```
