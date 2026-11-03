# EKS Deployment Guide — from zero to live, then delete everything

This guide takes you from "no AWS account" to the BSSONS store running on **Amazon EKS** with AWS Secrets Manager, TLS, monitoring and GitOps — and then shows how to **delete everything so you stop paying**.

> **Read this first**
> * **Cost:** roughly **US$0.40–0.50 per hour (about ₹40/hour, ₹900–1,000/day)** while the cluster exists (EKS control plane + 2 nodes + NAT gateway + load balancer + disks). Do the whole exercise in one sitting (3–4 hours) and run Part J the same day. Never leave it running overnight.
> * **Set a budget alarm first** (Part A3) so a mistake cannot become a surprise bill.
> * **Not verified in a live account.** This guide and the Terraform/manifests were written and syntax-checked without access to AWS. Small fixes (a module input, a chart version) are possible; the troubleshooting section (Part K) covers the likely ones.

## Map of the journey

| Part | What | Time |
|---|---|---|
| A | AWS account, safe admin user, budget alarm, tools | 30 min |
| B | GitHub repository + first green CI run | 30 min |
| C | Terraform bootstrap (state bucket, GitHub→AWS trust) | 10 min |
| D | Create the EKS cluster | 20 min |
| E | Secrets in AWS Secrets Manager + configure manifests | 10 min |
| F | Install Argo CD → platform + app deploy itself | 25 min |
| G | DNS and HTTPS | 15 min |
| H | Verify, release to prod, break things on purpose | 30 min |
| I | Watch the cost | 5 min |
| **J** | **Delete everything + verify nothing is billing** | **30 min** |
| K | Troubleshooting | — |

Terms used: **EKS** = AWS managed Kubernetes. **Terraform** = creates AWS resources from code. **Argo CD** = deploys what is in Git to the cluster. **External Secrets Operator (ESO)** = copies secrets from AWS Secrets Manager into Kubernetes. **IRSA** = lets a Kubernetes service account assume an AWS IAM role (no access keys).

---

## Part A — AWS account and tools

### A1. Create the account and protect the root user
1. Go to <https://aws.amazon.com> → **Create an AWS account** (needs a card; use a real e-mail you control).
2. Sign in as **root** → top-right account name → **Security credentials** → **Assign MFA device** (authenticator app). Root is only for billing/emergencies from now on.
3. Top-right region selector → choose **Asia Pacific (Mumbai) `ap-south-1`** (the default used everywhere in this project).

### A2. Create a non-root admin user for the exercise
1. Console → **IAM → Users → Create user** → name `bssons-admin` → leave "console access" off (CLI only).
2. **Attach policies directly → `AdministratorAccess`** → Create user. (Learning shortcut; a company would use SSO and scoped roles.)
3. Open the user → **Security credentials → Create access key → Command Line Interface (CLI)** → acknowledge → create. **Copy both values now** (the secret is shown once).
4. You will **delete this access key** in Part J.

### A3. Create a budget alarm (do not skip)
Console → **Billing and Cost Management → Budgets → Create budget → Use a template → Monthly cost budget** → amount **US$15** → your e-mail → create. You will be e-mailed at 85 % and 100 % of the amount.
(Also enable *Billing → Billing preferences → Receive billing alerts*.)

### A4. Install the tools on your computer (Linux / macOS / WSL2)
| Tool | Install | Check |
|---|---|---|
| AWS CLI v2 | <https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html> | `aws --version` |
| Terraform ≥ 1.6 | <https://developer.hashicorp.com/terraform/install> | `terraform -version` |
| kubectl | <https://kubernetes.io/docs/tasks/tools/> | `kubectl version --client` |
| Git, Node 20, Docker | as in the main README §2 | |
| GitHub CLI (`gh`) – optional | <https://cli.github.com> | `gh --version` |
| `jq`, `dig` – optional helpers | package manager | |

### A5. Connect the CLI to your account
```bash
aws configure
#  AWS Access Key ID     : <from A2>
#  AWS Secret Access Key : <from A2>
#  Default region name   : ap-south-1
#  Default output format : json
aws sts get-caller-identity        # must show your account id and user/bssons-admin
```
Never commit these keys anywhere. They live only in `~/.aws/credentials`.

---

## Part B — GitHub repository and first green pipeline

Do the main README **Step 1–4** first (they are short). In summary:

```bash
cd bssons-jewellers
cp .env.example .env               # fill passwords (see README §3)
make lock                          # generates package-lock.json for backend + frontend
make up && make seed               # optional: sanity check locally; then: make down
```

### B1. Replace placeholders for EKS
Pick **one**:

```bash
# (1) You own a domain (e.g. bssons.in): real HTTPS certificates from Let's Encrypt
scripts/init-project.sh <github-username> bssons-jewellers bssons.in you@email.com eks

# (2) No domain: self-signed HTTPS, hostnames mapped in your hosts file (Part G option 2)
scripts/init-project.sh <github-username> bssons-jewellers bssons.local you@email.com eks-nodomain
```
What the `eks` modes do beyond the normal replacement: they switch both overlays to **External Secrets** (secrets from AWS Secrets Manager) instead of Sealed Secrets.

### B2. Create a **public** repository and push
Public is recommended for this practice project: the repo contains **no secrets**, and it keeps Argo CD access, GitHub environments and branch protection free and simple. (Private repos on a free GitHub plan cannot enforce environment approvals or branch protection, and Argo CD would need a token.)

```bash
git init -b main
git add .
git commit -m "feat: initial production-grade BSSONS platform"
gh repo create bssons-jewellers --public --source=. --remote=origin --push
```
> The Terraform ESO role ARN will contain your AWS account id and end up in this public repo. An account id is an identifier, not a credential, but if that bothers you use a private repo and read the "private repo" notes in Part F.

### B3. Let the workflows work
GitHub → repo → **Settings**:
* **Actions → General → Workflow permissions** → tick **Allow GitHub Actions to create and approve pull requests**.
* **Environments → New environment** `production` (add yourself as *Required reviewer*) and `infrastructure` (same).
* **Skip branch protection for this first run** (otherwise the CI bot cannot commit the image tag; the README §5.3 explains the `GITOPS_PAT` option you can add later as an exercise).

### B4. Wait for the first CI run — this is mandatory before Argo CD
Repo → **Actions → CI**. All jobs must be green. On `main` it will:
1. build and push `ghcr.io/<you>/bssons-jewellers-backend` and `-frontend` tagged `sha-<12 chars>`,
2. commit the new tag into `k8s/overlays/staging/kustomization.yaml`.

Then:
```bash
git pull                                     # get the bot's commit
grep newTag k8s/overlays/staging/kustomization.yaml   # must show sha-..., not "latest"
```
**Why mandatory:** until a `sha-…` tag exists, the manifests point to `latest`, which was never pushed, so pods would fail with `ImagePullBackOff`.

### B5. Make the container images public
GitHub → your profile → **Packages** → open each of the two packages → **Package settings → Change visibility → Public**.
(A private registry works too: create a pull secret named `ghcr-pull` in each namespace — see Part K — the service accounts already reference it.)

If CI fails, fix it now using README §13; Trivy findings, lint errors and missing lockfiles are the usual causes.

---

## Part C — Terraform bootstrap (state storage + GitHub→AWS trust)

This is created **once, with local state**, from your laptop.

```bash
cd terraform/bootstrap
terraform init
terraform apply -var="github_repo=<github-username>/bssons-jewellers"     # type: yes
terraform output
```
Note these outputs: `state_bucket`, `lock_table`, `github_actions_role_arn`.

What this created: a private, versioned, encrypted S3 bucket for Terraform state; a DynamoDB lock table; the GitHub OIDC identity provider; and an IAM role only **your** repository can assume.

> If it fails with *EntityAlreadyExists … OpenIDConnect provider*, your AWS account already has the GitHub OIDC provider. Import it: `terraform import aws_iam_openid_connect_provider.github arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com` and re-apply.

Add the GitHub secret (optional, only needed if you want the Terraform workflow to run in GitHub): repo → **Settings → Secrets and variables → Actions → New repository secret** → `AWS_ROLE_ARN` = `github_actions_role_arn`.

---

## Part D — Create the EKS cluster

```bash
cd ../envs/dev                          # i.e. terraform/envs/dev
cp backend.hcl.example backend.hcl
# edit backend.hcl: replace <ACCOUNT_ID> with your 12-digit account id (aws sts get-caller-identity --query Account --output text)

# backend.hcl holds no secrets (bucket name only). Commit it if you want the GitHub "Terraform" workflow to work too.
terraform fmt -recursive ../..          # CI enforces formatting
terraform init -backend-config=backend.hcl
terraform plan -out tfplan              # read it: VPC, NAT, EKS, node group, IAM roles
terraform apply tfplan                  # ~15-20 minutes; type nothing, the plan is already approved
```
Connect kubectl and check:
```bash
$(terraform output -raw kubeconfig_command)     # same as: aws eks update-kubeconfig --region ap-south-1 --name bssons-dev
kubectl get nodes                               # 2 nodes, STATUS Ready
kubectl get pods -A                             # coredns, aws-node, kube-proxy, ebs-csi pods Running
```

### D1. Storage class for the database disks
```bash
kubectl get storageclass
# If a class named "gp2" is marked (default), un-default it first (two defaults confuse Kubernetes):
kubectl patch storageclass gp2 -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
cd ../../..                                      # back to repository root
kubectl apply -f k8s/platform/aws/storageclass-gp3.yaml
kubectl get storageclass                         # gp3 (default)
```

---

## Part E — Secrets and configuration

### E1. Create the database secrets in AWS Secrets Manager
From the repository root:
```bash
scripts/create-aws-secrets.sh staging
scripts/create-aws-secrets.sh prod
aws secretsmanager list-secrets --query 'SecretList[].Name' --output text    # bssons/prod/mongo  bssons/staging/mongo
```
Each secret holds `{"username": "...", "password": "..."}` with a random 48-hex-character password that is **never printed**. Console view: **Secrets Manager → Secrets → bssons/prod/mongo → Retrieve secret value**.

> Secrets Manager costs about **US$0.40 per secret per month** (prorated per hour) — a few cents for this exercise.

### E2. Feed the Terraform outputs into the manifests
```bash
scripts/configure-eks.sh
git add -A && git commit -m "chore: configure EKS role arn and region" && git push
```
This writes the ESO IAM role ARN into `argocd/apps-eks/external-secrets.yaml` and the region into `k8s/platform/aws/cluster-secret-store.yaml`. (CI will run again and, because the tag commit changes only `k8s/overlays/**`, will not loop. If it builds new images, `git pull` again.)

---

## Part F — Install Argo CD (everything else deploys itself)

```bash
scripts/bootstrap-argocd.sh --eks
```
Private repository? Create a token with *read access to repository contents* and run first:
`export ARGOCD_REPO_USER=<github-username> ARGOCD_REPO_TOKEN=<token>`.

The script installs Argo CD, then applies the project, the common platform (cert-manager, Prometheus/Grafana), the EKS platform (Traefik with an AWS load balancer, External Secrets + the secret store), and the `bssons-staging` / `bssons-prod` applications.

Watch it converge (10–20 minutes — Prometheus is big):
```bash
kubectl -n argocd get applications -w
```
Expected final state: every application **Synced / Healthy**, except `bssons-prod`, which is deliberately **manual** (and must not be synced until Part H3, because it still points to image tag `latest`).

Open the Argo CD UI:
```bash
kubectl -n argocd port-forward svc/argocd-server 9443:443        # leave running in a second terminal
# https://localhost:9443  - user: admin - password printed by the bootstrap script
```
### F1. Check the secret chain end to end
```bash
kubectl -n external-secrets get pods                       # operator Running
kubectl get clustersecretstore                             # aws-secrets-manager   Valid   True
kubectl -n bssons-staging get externalsecret               # bssons-secrets   SecretSynced   True
kubectl -n bssons-staging get secret bssons-secrets        # exists (created by ESO from AWS)
kubectl -n bssons-staging get pods                         # backend, frontend, mongo-0 Running
```
If `ClusterSecretStore` is not Valid, 90 % of the time it is the IAM role ARN annotation or region — see Part K.

---

## Part G — DNS and HTTPS

Get the load balancer address that Traefik received from AWS:
```bash
kubectl -n traefik get svc traefik
#  EXTERNAL-IP  ->  something like  a1b2c3...elb.ap-south-1.amazonaws.com   (may take 2-3 minutes)
```

### Option 1 — you own a domain (real HTTPS)
At your DNS provider (or Route 53) create two **CNAME** records pointing to that hostname:

| Name | Type | Value |
|---|---|---|
| `bssons.in` (use `www` or an `ALIAS/ANAME` if your provider forbids CNAME on the root) | CNAME | the ELB hostname |
| `staging.bssons.in` | CNAME | the ELB hostname |

Wait a few minutes, then:
```bash
kubectl get certificate -A            # READY True after ~1-3 minutes
kubectl -n bssons-staging describe certificate bssons-tls   # on trouble
curl -I https://staging.bssons.in
```
Staging uses the Let's Encrypt **staging** issuer (browsers show a warning — expected, it protects you from rate limits). Production uses the real issuer.
To get a trusted certificate on staging too, change `letsencrypt-staging` to `letsencrypt-prod` in `k8s/overlays/staging/kustomization.yaml` and push.

### Option 2 — no domain (self-signed)
```bash
nslookup <ELB hostname>               # note one of the IP addresses returned
```
Add to your hosts file (`/etc/hosts` on Linux/macOS; `C:\Windows\System32\drivers\etc\hosts` on Windows, as administrator):
```
<IP>  staging.bssons.local  bssons.local
```
Browse `https://staging.bssons.local` and accept the certificate warning. (NLB IPs can change if AWS replaces the load balancer; re-run `nslookup` if the site stops answering.)

### HTTP vs HTTPS note
Traefik serves both. A global HTTP→HTTPS redirect is intentionally not enabled because it would break Let's Encrypt's HTTP-01 validation; adding a per-route redirect middleware is one of the exercises in the README.

---

## Part H — Verify, release to production, break things on purpose

### H1. Load demo data and look around
```bash
kubectl -n bssons-staging exec deploy/backend -- env ALLOW_SEED=true node src/seed.js
curl -sk https://staging.<your-domain>/api/products | head -c 300
kubectl -n bssons-staging get pods,hpa,ingress,certificate,externalsecret
kubectl top pods -A | head                   # metrics-server is not installed by default on EKS: if this errors, skip it
```
Open the site in a browser; add items to the bag.

### H2. Monitoring
```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000  (user admin; password: see argocd/apps/common/kube-prometheus-stack.yaml - change it!)
```
Dashboards → **BSSONS API - RED metrics**. Generate traffic: `for i in $(seq 1 200); do curl -sk https://staging.<domain>/api/products >/dev/null; done`.

### H3. Promote to production (the real release flow)
1. GitHub → **Actions → Promote to production → Run workflow** (tag empty = what staging runs). Approve the `production` environment gate.
2. A pull request "Promote sha-… to production" appears → review and **merge** it.
3. `git pull`, then in the Argo CD UI open **bssons-prod → Sync** (or: `kubectl -n argocd patch application bssons-prod --type merge -p '{"operation":{"sync":{}}}'`).
4. `kubectl -n bssons get pods,externalsecret` → everything Running / SecretSynced. Open `https://<your-domain>`.

### H4. Break things on purpose (this is where you learn)
```bash
# 1. Self-healing: delete a pod
kubectl -n bssons-staging delete pod -l app=backend --wait=false && kubectl -n bssons-staging get pods -w

# 2. Drift correction: Argo reverts manual changes on staging
kubectl -n bssons-staging scale deploy/frontend --replicas=4      # watch it return to the Git value

# 3. Readiness vs liveness: database down -> backend NotReady, NOT restarted
kubectl -n bssons-staging scale statefulset/mongo --replicas=0
kubectl -n bssons-staging get pods -l app=backend                  # 0/1 Ready, RESTARTS unchanged
#   (Argo selfHeal restores the replica count within a few minutes)

# 4. Secret rotation through AWS (no Git change, no redeploy of manifests)
aws secretsmanager put-secret-value --secret-id bssons/staging/mongo --secret-string '{"username":"bssonsadmin","password":"newpassword123"}'
kubectl -n bssons-staging annotate externalsecret bssons-secrets force-sync=$(date +%s) --overwrite
kubectl -n bssons-staging get secret bssons-secrets -o jsonpath='{.data.mongo-password}' | base64 -d; echo   # shows the new value
#   WARNING: this only changes the Kubernetes secret. MongoDB itself still has the OLD password inside its data volume,
#   so the backend will now fail to log in - which is a perfect incident to diagnose with docs/RUNBOOK.md.
#   Restore: put the previous password back the same way (or delete the staging namespace PVC and let Argo recreate).

# 5. Rollback: git revert the last staging bump commit, push, watch Argo redeploy the previous image
```

---

## Part I — Watch the cost while it runs

* Console → **Billing and Cost Management → Cost Explorer** (data lags up to a day) and **Budgets**.
* Biggest items: EKS control plane, EC2 nodes, NAT gateway (hourly + data), network load balancer, EBS volumes.
* Set a phone alarm for **"DELETE EKS"** the moment you start. The longer it runs, the more you pay.

---

## Part J — Delete everything and verify nothing is billing

Order matters: delete the Kubernetes things first so AWS load balancers and disks created *by Kubernetes* are removed before Terraform deletes the network (otherwise `terraform destroy` hangs on dependencies).

### J1. Automated teardown (recommended)
From the repository root, with the cluster still reachable by kubectl:
```bash
scripts/teardown-eks.sh          # type "destroy" when asked
```
It: deletes the Argo CD applications (the cascade removes workloads, the load balancer and volumes) → deletes remaining PVCs → deletes the two AWS secrets (force, no recovery period) → runs `terraform destroy` for the cluster, VPC, NAT and IAM roles. About 15–25 minutes.

### J2. Manual equivalent (to understand what happens)
```bash
# 1. Remove the workload apps first, then the platform "root" apps (roots self-heal, so delete the root, not its children)
kubectl -n argocd delete application bssons-staging bssons-prod --ignore-not-found --wait --timeout=10m
kubectl -n argocd delete application platform-eks platform-common platform-kind --ignore-not-found --wait --timeout=15m
# 2. Disks (StatefulSet PVCs are NOT deleted automatically)
for ns in bssons bssons-staging monitoring; do kubectl -n $ns delete pvc --all --wait --timeout=5m; done
# 3. Confirm the load balancer Service is gone (this deletes the AWS NLB)
kubectl get svc -A | grep LoadBalancer      # must print nothing
# 4. Secrets Manager
aws secretsmanager delete-secret --secret-id bssons/staging/mongo --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id bssons/prod/mongo --force-delete-without-recovery
# 5. Infrastructure
cd terraform/envs/dev && terraform destroy         # type: yes
```

### J3. Delete the bootstrap stack too (state bucket, lock table, GitHub trust)
These cost only cents, but you said you want everything gone:
```bash
cd terraform/bootstrap
terraform apply -var="github_repo=<github-username>/bssons-jewellers" -var="force_destroy=true"   # allows deleting the non-empty bucket
terraform destroy -var="github_repo=<github-username>/bssons-jewellers" -var="force_destroy=true"
```
(Destroying the state bucket also deletes the record of the environment you just destroyed — that is fine now because everything is gone.)

### J4. Verify nothing is left (copy-paste; every command should print nothing / empty)
```bash
R=ap-south-1
aws eks list-clusters --region $R
aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId'
aws ec2 describe-addresses --region $R --query 'Addresses[].PublicIp'                          # elastic IPs (billed if unattached)
aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName'
aws elb describe-load-balancers --region $R --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws ec2 describe-volumes --region $R --filter Name=status,Values=available --query 'Volumes[].VolumeId'
aws ec2 describe-instances --region $R --filter Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId'
aws secretsmanager list-secrets --region $R --query 'SecretList[].Name'
aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks --query 'logGroups[].logGroupName'
aws kms list-aliases --region $R --query "Aliases[?contains(AliasName,'bssons')].AliasName"     # may show keys 'pending deletion' - they stop billing after the wait period
aws s3 ls | grep bssons-tfstate
aws iam list-roles --query "Roles[?contains(RoleName,'bssons')].RoleName"
```
Anything printed = a leftover. Delete it in the console (EC2 → Volumes / Load Balancers / Elastic IPs, etc.) and look at the **VPC** console for a leftover `bssons-dev-vpc` (delete security groups/ENIs that block it).

### J5. Final clean-up
1. IAM → Users → `bssons-admin` → **Security credentials** → **Deactivate and delete the access key**; then optionally delete the user. Remove the profile from `~/.aws/credentials`.
2. Delete the `AWS_ROLE_ARN` GitHub secret.
3. Next day: **Cost Explorer** should show the charges stopped. Keep the budget alarm for a month.
4. Delete the GitHub repository only if you no longer need it as your portfolio project.

---

## Part K — Troubleshooting (EKS-specific)

| Symptom | Likely cause → fix |
|---|---|
| `terraform apply` fails on `aws_eks_addon`/node group "AMI not found" | Kubernetes version/AMI mismatch. Check <https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html>, pick a version in standard support in `terraform/envs/dev/variables.tf`, re-plan |
| `terraform init` complains about backend | `backend.hcl` missing/wrong bucket name; re-copy from the example |
| `terraform destroy` hangs deleting the VPC/subnets | A load balancer or ENI created by Kubernetes still exists → re-do J2 steps 1–3, delete the LB in the EC2 console, retry |
| Nodes `NotReady` / pods `Pending: Too many pods` | Node limit reached → raise `node_min_size`/`node_max_size` in `variables.tf` and apply, or pick a larger instance type |
| `Pending` PVC for mongo | No default StorageClass → Part D1; check `kubectl describe pvc` and that the `aws-ebs-csi-driver` addon is ACTIVE |
| `ClusterSecretStore` not Valid (`AccessDenied`, `WebIdentityErr`) | Role ARN annotation wrong (re-run `scripts/configure-eks.sh`, push, let Argo sync), service account name must be `external-secrets` in namespace `external-secrets`, region mismatch |
| `ExternalSecret` `SecretSyncedError: Secret does not exist` | Name typo or wrong region; list with `aws secretsmanager list-secrets`; names must be exactly `bssons/staging/mongo` and `bssons/prod/mongo` |
| `no matches for kind ExternalSecret/ClusterSecretStore ... v1beta1` | The ESO chart is newer than the manifests. `kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}'` — if it lists `v1` only, change `apiVersion` to `external-secrets.io/v1` in `k8s/overlays/*/external-secret.yaml` and `k8s/platform/aws/cluster-secret-store.yaml` |
| Pods `ImagePullBackOff` | Tag still `latest` (Part B4 skipped) or package still private (B5). Private option: `kubectl -n bssons-staging create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username=<user> --docker-password=<classic PAT with read:packages>` (repeat for `bssons`) |
| Certificate stuck `False` | Option 1: DNS not pointing to the ELB yet; check `kubectl describe challenge -A`. Option 2: you used the `eks` mode instead of `eks-nodomain` (Let's Encrypt cannot validate `.local`) |
| Argo app `ComparisonError` / chart version not found | `targetRevision: "*"` resolved to something incompatible; pin to a known-good version (see README "Pin chart versions") |
| Prometheus pod `Pending` | Not enough memory on 2 nodes → raise node count or reduce retention |
| `kubectl` says "You must be logged in" | `aws sts get-caller-identity` must be the same user that ran `terraform apply`; re-run the `update-kubeconfig` command |
