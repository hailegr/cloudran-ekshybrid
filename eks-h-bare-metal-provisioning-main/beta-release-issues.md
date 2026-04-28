# Beta Release Issues

## ISSUE 1: README Quick Start step 4 references wrong values.yaml path

**Severity:** High — blocks first-time setup

**Description:**
The README Quick Start step 4 (line 69) instructs users to run:

```bash
helm template <cluster> charts/mgmt-bootstrap/ -f values.yaml | kubectl apply -f -
```

This fails with `Error: open values.yaml: no such file or directory` because no `values.yaml` exists at the repository root. The actual Helm values file is located at `charts/values.yaml`.

Additionally, step 2 tells users to `cp values.example.yaml values.yaml`, but no `values.example.yaml` exists at the root either.

**Fix:**
Update the README to reference the correct path:

```bash
helm template <cluster> charts/mgmt-bootstrap/ -f charts/values.yaml | kubectl apply -f -
```

Or add a `values.example.yaml` at the repo root as the README expects.

## ISSUE 2: README step 5 fails when project is downloaded as zip instead of cloned

**Severity:** Medium — blocks Git push setup

**Description:**
The README Quick Start step 5 instructs users to run:

```bash
git remote set-url origin <CodeCommitRepoURL from CDK outputs>
```

This fails with `fatal: not a git repository (or any of the parent directories): .git` when the project was downloaded as a zip/tarball (e.g., from GitHub's "Download ZIP") rather than `git clone`'d. The `git remote set-url` command requires an existing git repo with a configured remote.

**Fix:**
Update the README to handle both cases. For zip downloads, users need to initialize the repo first:

```bash
git init
git add -A
git commit -m "Initial commit"
git remote add origin <CodeCommitRepoURL from CDK outputs>
git push -u origin main
```

Or add a note clarifying that the project must be `git clone`'d, not downloaded as a zip.
