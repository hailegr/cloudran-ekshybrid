# Secret Management Options

## Summary

BMC credentials (username/password) are currently stored in plain text in server-group YAML files. Default credentials have been removed from the RGD and chart templates, but the values in `server-groups/<cluster>/<group>.yaml` are still unencrypted. This document evaluates options for encrypting these secrets while maintaining the GitOps workflow. The recommended approach depends on whether the EKS ArgoCD Capability adds plugin support — if it does, SOPS+KMS is the cleanest; if not, External Secrets Operator with Parameter Store SecureString is the most practical.

---

## Current State

- `server-groups/<cluster>/<group>.yaml` contains `bmcUser` and `bmcPass` in plain text
- These files are gitignored by default but must be pushed to CodeCommit for ArgoCD to access them
- The bare-metal Helm chart creates `BareMetalInventory` CRs which include BMC credentials
- kro's inventory RGD creates a K8s Secret (`<server>-bmc`) from the CR fields
- The K8s Secret is used by Tinkerbell's Rufio to authenticate with the BMC

## Requirements

- Secrets must be encrypted at rest in Git
- Decryption must happen automatically during ArgoCD sync or on the cluster
- Must work with the EKS ArgoCD Capability (managed, no pod-level customization)
- Per-cluster secrets are acceptable (BMC credentials are site-specific)
- No manual decryption steps in the provisioning flow

---

## Option 1: SOPS + AWS KMS

**How it works:** Mozilla SOPS encrypts individual YAML values using a KMS key. The YAML structure stays readable — only values are encrypted. A kustomize plugin (ksops) or ArgoCD CMP sidecar decrypts at sync time.

**Pros:**
- Cleanest GitOps experience — encrypted values in the same YAML files
- Diffs are readable (keys visible, only values encrypted)
- KMS-based — IAM controls who can encrypt/decrypt
- Industry standard for GitOps secret management

**Cons:**
- Requires a Config Management Plugin (CMP) sidecar on the ArgoCD repo-server
- **EKS ArgoCD Capability does NOT support custom plugins** — this is a blocker
- Would work with self-managed ArgoCD but not the managed capability

**Verdict:** Blocked by EKS ArgoCD Capability limitations. Revisit if AWS adds CMP support.

**Implementation notes for future:**
- Create KMS key in CDK stack, grant `kms:Decrypt` to ArgoCD capability role
- Add `.sops.yaml` to repo root with creation rules targeting `server-groups/**/*.yaml`
- Encrypt with: `sops -e -i server-groups/<cluster>/<group>.yaml`
- Install ksops as a kustomize plugin or CMP sidecar on ArgoCD

---

## Option 2: Sealed Secrets

**How it works:** Bitnami Sealed Secrets controller runs on the cluster. You encrypt secrets locally using the cluster's public key (`kubeseal`). The encrypted `SealedSecret` CR is committed to Git. The controller decrypts it on the cluster and creates a regular K8s Secret.

**Pros:**
- No ArgoCD plugin needed — SealedSecret is a regular K8s CRD
- Works with managed ArgoCD
- Encrypted resources are safe to commit to Git
- Controller is a simple Helm chart, deployed via ArgoCD

**Cons:**
- Cluster-specific encryption — secrets encrypted for one cluster can't be decrypted by another
- If the cluster is recreated, the encryption key changes — all secrets must be re-encrypted
- Requires `kubeseal` CLI for the operator to encrypt secrets (extra tooling)
- The encryption key (stored as a K8s Secret on the cluster) must be backed up

**Verdict:** Works today with managed ArgoCD. Good fit if secrets are per-cluster (BMC credentials are). Operational overhead for key management and re-encryption on cluster recreation.

**Implementation notes for future:**
- Add Sealed Secrets controller as an ArgoCD app (sync wave -10, before bare-metal apps)
- Operator workflow: `kubeseal --fetch-cert --controller-namespace tinkerbell > pub-cert.pem`
- Encrypt: `kubeseal --cert pub-cert.pem --format yaml < bmc-secret.yaml > sealed-bmc-secret.yaml`
- Change bare-metal chart to emit SealedSecret instead of plain Secret for BMC credentials
- Back up the controller's signing key: `kubectl get secret -n tinkerbell -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > backup.yaml`

---

## Option 3: External Secrets Operator + AWS Parameter Store

**How it works:** External Secrets Operator (ESO) runs on the cluster. It reads secrets from AWS Parameter Store (or Secrets Manager) and creates K8s Secrets. The Parameter Store paths are defined in `ExternalSecret` CRs committed to Git — no actual secret values in Git.

**Pros:**
- No secret values in Git at all — only references (Parameter Store paths)
- Works with managed ArgoCD — ESO is a regular K8s controller
- Parameter Store SecureString is free (standard tier, up to 10,000 parameters)
- SecureString uses KMS encryption (AWS-managed or customer CMK)
- Cross-cluster — same Parameter Store paths work across cluster recreations
- CloudTrail audit trail for all secret access

**Cons:**
- Requires storing secrets in Parameter Store (separate from Git workflow)
- Two sources of truth — server inventory in Git, credentials in Parameter Store
- ESO controller + CRDs add complexity to the cluster
- Parameter Store has no native cross-account access (need IAM role chaining)
- Requires Pod Identity or IRSA for ESO to access Parameter Store

**Cost comparison:**
- Parameter Store standard SecureString: **free** (up to 10,000 params, KMS-encrypted)
- Secrets Manager: **$0.40/secret/month** (100 secrets = $40/month)
- Both charge $0.05 per 10,000 API calls

**Verdict:** Most practical option that works today. No Git encryption needed — secrets never touch Git. Parameter Store SecureString with a customer-managed KMS key provides equivalent security to Secrets Manager at zero cost.

**Implementation notes for future:**
- Add ESO Helm chart as an ArgoCD app on workload clusters
- Create a Pod Identity association for ESO (needs `ssm:GetParameter` + `kms:Decrypt`)
- Store BMC credentials in Parameter Store: `/eks-h/<cluster>/<server>/bmc-user`, `/eks-h/<cluster>/<server>/bmc-pass`
- Create `ExternalSecret` CRs in the bare-metal chart instead of inline `bmcUser`/`bmcPass`
- The `BareMetalInventory` CR would reference the K8s Secret created by ESO
- Populate Parameter Store via CLI: `aws ssm put-parameter --name /eks-h/<cluster>/<server>/bmc-pass --value <pass> --type SecureString`

---

## Option 4: Git-crypt

**How it works:** git-crypt transparently encrypts files in Git using GPG or a symmetric key. Files are decrypted on checkout if the key is available.

**Pros:**
- Transparent — encrypted files look normal after checkout
- Simple setup

**Cons:**
- Encrypts entire files, not individual values (diffs are unreadable)
- ArgoCD needs the decryption key — managed ArgoCD can't have it
- **Does not work with EKS ArgoCD Capability**

**Verdict:** Not viable with managed ArgoCD.

---

## Recommendation Matrix

| Criteria | SOPS+KMS | Sealed Secrets | ESO+Parameter Store | Git-crypt |
|----------|----------|---------------|-------------------|-----------|
| Works with managed ArgoCD | ❌ | ✅ | ✅ | ❌ |
| Secrets in Git (encrypted) | ✅ | ✅ | ❌ (refs only) | ✅ |
| Cross-cluster | ✅ | ❌ | ✅ | ✅ |
| No extra tooling for operator | ❌ (sops CLI) | ❌ (kubeseal CLI) | ✅ (AWS CLI) | ❌ (git-crypt) |
| Survives cluster recreation | ✅ | ❌ (re-encrypt) | ✅ | ✅ |
| Cost | Free (KMS) | Free | Free (Param Store) | Free |
