# Ralph Loop (Kubernetes)

Helm chart and tooling for running the [Ralph Loop](https://github.com/alphadose/ralph) AI automation job on Kubernetes.

## Prerequisites

- Docker (for building and pushing the image)
- [Just](https://github.com/casey/just) (command runner)
- Helm 3, kubectl
- A Kubernetes cluster with a namespace, a PVC for workspace data, and an SSH key secret for cloning repos (see chart defaults below)

## Configuring the registry

The image is built with Just and pushed to a registry; the Helm chart pulls the same image. Configure both places so they match.

### 1. Justfile (build and push)

At the top of the [Justfile](Justfile) set:

| Variable      | Purpose                    | Example                          |
|---------------|----------------------------|----------------------------------|
| `REGISTRY`    | Registry host (and port)   | `docker.io` or `myreg.io:5000`   |
| `IMAGE_NAME`  | Image name (no tag)       | `ralph-polyglot-base`            |
| `IMAGE_TAG`   | Tag for build/push        | `latest`                         |

Example for Docker Hub as `myorg/ralph-polyglot-base:latest`:

```just
REGISTRY := "docker.io"
IMAGE_NAME := "myorg/ralph-polyglot-base"
IMAGE_TAG := "latest"
```

Example for a private registry:

```just
REGISTRY := "registry.example.com:32000"
IMAGE_NAME := "ralph-polyglot-base"
IMAGE_TAG := "latest"
```

Then run:

```bash
just build
```

### 2. Helm chart (where to pull the image)

The chart uses `image.repository` and `image.tag`. Either:

- **Option A:** Edit [.helm/values.yaml](.helm/values.yaml) and set:

  ```yaml
  image:
    repository: docker.io/myorg/ralph-polyglot-base   # or your-registry/your-image
    tag: latest
    pullPolicy: IfNotPresent
  ```

- **Option B:** Override when installing/upgrading, e.g.:

  ```bash
  helm upgrade --install ralph .helm -n ralph -f my-values.yaml \
    --set image.repository=registry.example.com:32000/ralph-polyglot-base \
    --set image.tag=latest
  ```

Use the same repository and tag as in the Justfile so `just build` and the chart point at the same image.

## Configuring the Justfile (release and values)

At the top of the [Justfile](Justfile):

| Variable       | Purpose                              | Default              |
|----------------|--------------------------------------|----------------------|
| `RELEASE_NAME` | Helm release name prefix             | `ralph`              |
| `NAMESPACE`    | Kubernetes namespace                 | `ralph`              |
| `VALUES_FILE`  | Base values file for Helm            | `.helm/values.yaml`   |
| `CHART_DIR`    | Path to the Helm chart               | `.helm`               |

- **RELEASE_NAME** – Used for releases like `ralph` or `ralph-myproject` when you run `just start myproject`.
- **NAMESPACE** – Create this namespace (and the PVC + secret) before installing.
- **VALUES_FILE** – Base defaults; project-specific values are merged via `just start <name>` using `&lt;name&gt;-values.yaml`.

### Using project-specific values

1. Copy the example and name it after your project:

   ```bash
   cp example-values.yaml myproject-values.yaml
   ```

2. Edit `myproject-values.yaml`: set `job.name`, `job.repoUrl`, `job.branch`, `job.runtime`, `job.aiProvider`, `job.project`, `job.expertise`, `job.aiModel`, `job.prd`, etc.

3. Run:

   ```bash
   just start myproject
   ```

   This runs `helm upgrade --install ralph-myproject .helm -n ralph -f .helm/values.yaml -f myproject-values.yaml` (with auth disabled for the job). The name you pass to `just start` must match the values filename: `just start foo` uses `foo-values.yaml`.

## Quick start

1. Configure registry and image (Justfile + `.helm/values.yaml` or your values file) as above.
2. Ensure the cluster has the namespace, PVC (`global.sessionPvcName`), and SSH secret (`global.sshSecretName`) used by the chart.
3. Build and push the image: `just build`
4. One-time auth for AI providers: `just auth` (then run `claude login` or `gemini login` in the pod and exit).
5. Create a project values file (e.g. `myproject-values.yaml`) from `example-values.yaml`, then start the job: `just start myproject`
6. Follow logs: `just logs myproject`

## Commands (Just)

| Command              | Description                    |
|----------------------|--------------------------------|
| `just build`         | Build and push Docker image   |
| `just auth`          | Deploy auth pod, exec in to log in to AI providers, then uninstall |
| `just start <name>`  | Install/upgrade release using `<name>-values.yaml` |
| `just logs <name>`   | Stream logs for the job       |
| `just stop <name>`   | Uninstall the release         |
| `just cleanup <name>`| Run cleanup job (rescue changes, reset branch) |
| `just list`          | List Ralph releases and jobs  |
| `just helm-lint`     | Lint the Helm chart           |

## License

See the project’s license file.
