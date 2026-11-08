# Smart Retail Inventory – DevOps

Infrastructure for the Smart Retail Inventory system: Kubernetes manifests, CI/CD pipeline and monitoring.
Application source code lives in the `inventory-app` repository.

## Repository layout

```
inventory-devops/
├── k8s/                        Kubernetes manifests, applied in file-name order
│   ├── 00-namespace.yaml       Namespace "inventory" with Pod Security labels
│   ├── 01-configmap.yaml       Non-secret settings
│   ├── 10-postgres.yaml        PostgreSQL StatefulSet + persistent volume + internal Service
│   ├── 20-backend.yaml         Flask API Deployment + Service (replica count owned by the HPA)
│   ├── 30-frontend.yaml        React/nginx Deployment + Service
│   ├── 40-ingress.yaml         Ingress for http://inventory.local
│   ├── 50-simulator.yaml       CronJobs simulating store activity (sales, deliveries, new products)
│   ├── 60-hpa.yaml             HorizontalPodAutoscaler for the backend (2-5 pods)
│   └── 70-backup.yaml          Nightly pg_dump backup CronJob with 7-day retention
├── Jenkinsfile                 CI/CD pipeline
├── monitoring/
│   ├── values.yaml             kube-prometheus-stack settings (Prometheus + Grafana)
│   ├── dashboards/             Grafana dashboard as code (JSON)
│   └── manifests/              ServiceMonitor, Grafana Ingress
├── jenkins/
│   ├── Dockerfile              Jenkins controller with docker CLI, kubectl, helm, Python, Node
│   └── plugins.txt             Plugins baked into the image
├── scripts/
│   ├── deploy.sh               Deploys one release (image tag) and waits until it is healthy
│   ├── create-secret.sh        Creates the database Secret with a random password
│   ├── restore-backup.sh       Lists backups / restores the database from a backup
│   ├── smoke-test.sh           API test against the live deployment (used by the pipeline)
│   ├── install-monitoring.sh   Installs/updates Prometheus + Grafana (used by the pipeline)
│   ├── start-jenkins.sh        Builds and starts Jenkins, writes its kubeconfig
│   ├── bootstrap.sh            One-command install on a fresh machine (no Jenkins needed)
│   ├── dev-up.sh               Starts Minikube, Jenkins and the port forward after a reboot
│   └── dev-down.sh             Stops the port forward (--all: also Jenkins and Minikube)
├── tools/
│   └── load-generator.yaml     On-demand load for the autoscaling demo (not deployed by default)
└── examples/
    └── secret.example.yaml     Secret format reference (placeholders only, never applied)
```

## Requirements coverage

Course project #1, "Smart Retail Inventory System". Paths starting with `inventory-app/` are in the application repository; all others are in this repository.

| Requirement | Implementation |
|---|---|
| Flask REST API: product CRUD, restocking | `inventory-app/backend/app.py` — all 9 endpoints from the brief, plus `/health`, `/ready`, `/metrics` |
| Stock analytics and trends | `GET /api/products/low-stock`, `GET /api/products/analytics` |
| React frontend with charts (optional) | `inventory-app/frontend/src/` — React 18, Vite, Chart.js |
| PostgreSQL: products, stock levels, restock logs | `inventory-app/backend/db.py` — `products`, `stock_history`, `restock_logs` (+ `sales`, `settings`) |
| Separate Dockerfiles | `inventory-app/backend/Dockerfile`, `inventory-app/frontend/Dockerfile` (multi-stage) |
| docker-compose for local development (optional) | `inventory-app/docker-compose.yml` |
| ConfigMaps | `k8s/01-configmap.yaml` |
| Secrets for PostgreSQL credentials | `scripts/create-secret.sh` (random password, never in Git); format in `examples/secret.example.yaml` |
| Deployments for Flask, React, PostgreSQL | `k8s/20-backend.yaml`, `k8s/30-frontend.yaml`; PostgreSQL uses a StatefulSet (`k8s/10-postgres.yaml`) for a stable identity and persistent volume |
| Services | ClusterIP Services in `k8s/10-*`, `k8s/20-*`, `k8s/30-*` |
| Ingress | `k8s/40-ingress.yaml` (app), `monitoring/manifests/grafana-ingress.yaml` (Grafana) |
| Prometheus: API response times, container resources | `monitoring/values.yaml`, `monitoring/manifests/servicemonitor.yaml` |
| Grafana: stock trends and API latency | `monitoring/dashboards/smart-retail-inventory.json` (dashboard as code) |
| Split Git repositories | `inventory-app` (code, Dockerfiles) and `inventory-devops` (manifests, Jenkinsfile, monitoring) |
| CI/CD: lint Flask and React | `Jenkinsfile` stage *Lint* (flake8, ESLint in parallel) |
| CI/CD: unit tests | Stage *Unit tests* — 35 pytest tests, JUnit report |
| CI/CD: build and push to Docker Hub | Stages *Build images*, *Push images* — tagged with the app commit SHA |
| CI/CD: deploy to Minikube | Stage *Deploy* — `scripts/deploy.sh` applies the manifests with the new tag and waits for healthy rollouts |
| CI/CD: run Prometheus and Grafana | Stage *Monitoring* — `scripts/install-monitoring.sh` (Helm) |
| CI/CD: API testing on the live deployment | Stage *API tests* — `scripts/smoke-test.sh` through the Ingress |
| Automatic deploys with health checks | Poll every minute; liveness/readiness/startup probes; `rollout status`; automatic rollback to the exact previous release on failure |

**Beyond the brief:** atomic stock updates (a sale can never push stock below zero, even with concurrent requests), Trivy image scanning that blocks the push, HorizontalPodAutoscaler (2–5 backend pods), store-simulator CronJobs controlled from the dashboard, nightly `pg_dump` backups that are verified before they are kept, with a scripted restore, graceful shutdown (`preStop`), a startup lock for concurrent replicas, Swagger API docs, Pod Security Admission, non-root containers with dropped capabilities, and a one-command install (`scripts/bootstrap.sh`).

## Try it on your machine

With Docker, Minikube, kubectl and Helm installed:

```bash
git clone <this repository> inventory-devops && cd inventory-devops
./scripts/bootstrap.sh
```

The script starts Minikube, deploys the latest published images from Docker Hub, installs monitoring and opens access on port 8080. It takes about 10 minutes the first time (image downloads). Jenkins is not needed for this.

## Architecture

```
Browser -> Ingress (inventory.local) -> frontend Service -> frontend Pod (nginx)
                                                               | /api
                                                               v
                                        backend Service -> backend Pods x2 (Flask)
                                                               |
                                                               v
                                       postgres Service -> postgres Pod -> PersistentVolume
```

## Deploy a specific release by hand

`bootstrap.sh` covers a fresh machine. To deploy one release (the image tag is the app commit SHA) to a running cluster:

```bash
./scripts/deploy.sh 1a2b3c4
kubectl get pods -n inventory
```

This is the same script the pipeline uses, so a manual deploy and a pipeline deploy behave the same way.

## Daily use

After a reboot, one command brings everything back:

```bash
./scripts/dev-up.sh
```

| Service | URL |
|---|---|
| App | http://inventory.local:8080 |
| Grafana | http://grafana.local:8080 |
| Jenkins | http://localhost:8081 |

Both `.local` names resolve through the hosts file (`127.0.0.1 inventory.local grafana.local`). A single background port-forward to the Ingress controller serves both; Grafana and the app are routed by host name. `./scripts/dev-down.sh` stops it, `./scripts/dev-down.sh --all` also stops Jenkins and Minikube.

## CI/CD pipeline

Jenkins polls both repositories every minute. A new commit in `inventory-app` runs:

| Stage | What it does |
|---|---|
| Checkout | Clones `inventory-app`; the image tag is the app commit SHA |
| Lint | flake8 (backend) and ESLint (frontend), in parallel |
| Unit tests | pytest, results published as JUnit reports |
| Build images | Backend and frontend images tagged with the commit SHA |
| Security scan | Trivy; the build stops on fixable CRITICAL vulnerabilities, before anything is pushed |
| Push images | Docker Hub, logging in with an access token stored as a Jenkins credential |
| Deploy | Applies `k8s/` with the new tag and waits for the rollouts to become healthy |
| Monitoring | Installs/updates kube-prometheus-stack with Helm at a fixed chart version; a failure here marks the build unstable but keeps the release |
| API tests | `scripts/smoke-test.sh` against the live Ingress: every endpoint in the brief, including rejected oversell and 404 after delete |

The Deploy stage records which release is running before it starts. If anything fails after the deploy, the pipeline deploys that exact release again.

### Running Jenkins locally

```bash
./scripts/start-jenkins.sh
```

Jenkins listens on http://localhost:8081 (bound to localhost only). Credentials to create in Jenkins:

| ID | Type | Value |
|---|---|---|
| `dockerhub` | Username with password | Docker Hub user and an access token (Read & Write) |
| `minikube-kubeconfig` | Secret file | `~/jenkins-kubeconfig`, written by the start script |

Creating the job (once):

1. Open http://localhost:8081 and unlock Jenkins with the initial password: `docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword`.
2. Add the two credentials above (*Manage Jenkins → Credentials*).
3. *New Item* → name `inventory` → *Pipeline*.
4. Under *Pipeline*, choose *Pipeline script from SCM* → Git, the URL of this repository, branch `main`, script path `Jenkinsfile`.
5. Run the first build by hand. It registers the polling trigger; after that, every push to either repository starts a build within a minute.

The pipeline clones `inventory-app` from the same GitHub account without credentials, so that repository must be public.

**Lab-only shortcuts.** The Jenkins container mounts the host Docker socket and uses the Minikube admin kubeconfig. Both are acceptable on a single-user laptop, but give the pipeline full control of the host and cluster. In production the builds would run on isolated agents, images would be built with a daemonless tool such as Kaniko or BuildKit, and the pipeline would deploy with a namespace-scoped ServiceAccount.

## Monitoring

The pipeline installs kube-prometheus-stack into the `monitoring` namespace. Prometheus scrapes the backend's `/metrics` every 15 seconds through a ServiceMonitor. The "Smart Retail Inventory" dashboard is kept as JSON in `monitoring/dashboards/`; the install script packs it into a ConfigMap that Grafana loads automatically.

| Dashboard row | Panels |
|---|---|
| Store | Low-stock and sold-out products, units sold today, units on shelves, stock value |
| API | Requests per second, p50/p95 response time, 5xx error rate |
| Kubernetes | CPU and memory per pod, backend replicas (HPA) |

Grafana is at http://grafana.local:8080. Log in as `admin` with the generated password:

```bash
kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## Demo scenarios

**Self-healing** – delete a backend pod; the other replica keeps serving while Kubernetes replaces it:

```bash
kubectl delete pod -n inventory -l app=backend --wait=false
kubectl get pods -n inventory -l app=backend -w
```

**Live store activity** – the simulator CronJobs sell products every minute and launch a new product every two minutes:

```bash
kubectl get cronjobs -n inventory
kubectl logs -n inventory -l app=simulator --tail=20
```

**Autoscaling** – generate load and watch the backend scale from 2 to 5 pods, then back down:

```bash
kubectl apply -f tools/load-generator.yaml
kubectl get hpa backend -n inventory -w
kubectl delete -f tools/load-generator.yaml
```

**Backup and restore**:

```bash
kubectl create job backup-now --from=cronjob/postgres-backup -n inventory
kubectl logs -n inventory job/backup-now
./scripts/restore-backup.sh                          # list backups
./scripts/restore-backup.sh inventory-XXXX.sql.gz    # restore one
```

The restore pauses the backend and the simulator, replaces the data in a single transaction (a broken file leaves the old data untouched), then starts them again.

## Design decisions

| Topic | Decision |
|---|---|
| Secrets | Database password generated by `create-secret.sh` and stored only in the cluster. Git holds placeholders only. |
| Network exposure | Only the Ingress is reachable from outside. PostgreSQL and the backend are `ClusterIP` services. |
| Availability | Backend runs at least 2 replicas (HPA minimum) with `maxUnavailable: 0` rolling updates. |
| Health checks | Backend: startup + liveness on `/health`, readiness on `/ready` (checks the database). Frontend: `/healthz`. PostgreSQL: `pg_isready`. |
| Persistence | PostgreSQL uses a StatefulSet with a 1Gi PersistentVolumeClaim. |
| Resources | Every container has CPU and memory requests and limits. |
| Pod security | Namespace enforces the `baseline` Pod Security Standard and warns on `restricted`. Backend and frontend run as non-root with all capabilities dropped; the backend root filesystem is read-only. |
| Images | Pinned to the Git commit SHA, never `latest`. |
| Scaling | HPA scales the backend on CPU (70% of request), 2 to 5 replicas, 60s scale-down window. |
| Backups | Daily `pg_dump` to a dedicated volume; each file is checked with `gunzip -t` before it replaces older ones; 7 newest kept; scripted restore. |
| Demo data | Simulator CronJobs use the public API only, with `concurrencyPolicy: Forbid` and a bounded catalog. |

## Known limitations

| Limitation | Reason |
|---|---|
| Unit tests run on SQLite, not PostgreSQL | Keeps the CI stage fast and self-contained. PostgreSQL-specific behaviour (advisory lock, `RETURNING`, date casts) is covered by the API tests against the live deployment. |
| PostgreSQL runs as root inside its container | The official image needs it to set up a Minikube `hostPath` volume. The namespace enforces `baseline`, which allows this; backend and frontend are non-root. |
| Jenkins has full access to the host Docker and the cluster | See *Lab-only shortcuts* above. |
| Single-node cluster | Replicas protect against a crashed pod, not a failed machine. |

## Useful commands

```bash
kubectl get all -n inventory                         # everything in the namespace
kubectl logs -n inventory deploy/backend             # backend logs
kubectl describe pod -n inventory <pod-name>         # why a pod is not starting
kubectl top pods -n inventory                        # CPU / memory usage
kubectl rollout restart -n inventory deploy/backend  # restart backend pods one by one
```
