# Safety Guardrails for Terraform CE to TFE Migrations

## 1. Absolute Prohibition of Destructive Operations
- **No Unattended Infrastructure Changes**: Never execute `terraform apply`, `terraform destroy`, `terraform taint`, or `terraform untaint` against target environments.
- **No Unattended State Mutations**: Never execute `terraform state rm` or direct state overwrites. State migration operations must be formatted as step-by-step human-in-the-loop runbooks.
- **No Destructive Platform Deletions**: Never execute `tfctl ... delete` or automated workspace/variable deletion commands without explicit human intervention.

## 2. Zero Plaintext Secrets Policy
- **No Raw Credentials**: Never hardcode, display, or commit plaintext secrets (passwords, tokens, private keys, API secrets) into `.tf`, `.tfvars`, pipeline scripts, or output logs.
- **TFE Variable Sets**: When migrating sensitive variables from local `.tfvars` or environment variables, reference TFE Variable Sets and instruct operators to populate sensitive values securely via TFE UI or enterprise CI/CD secret stores.

## 3. Platform Grounding via tfctl
- **Always Preview with Dry-Run**: When generating platform resource specifications (workspaces, teams, projects), use `tfctl ... --dry-run` or `--json` to validate schemas.
- **Schema Discovery**: Use `tfctl api schema search <keyword>` to discover exact OpenAPI payload schemas rather than assuming API parameter names.

## 4. Git and Change Control
- **One Branch Per Repository**: All automated code transformations must be generated on a dedicated migration branch (e.g., `migration/tfe-<workspace-name>`).
- **Pull Request Boundary**: Deliver all code changes as Git Pull Requests for team code review before merging.
- **Zero-Diff Verification**: Every migration requires a zero-diff `terraform plan` verification (`0 to add, 0 to change, 0 to destroy`) before retiring legacy CE backends.
