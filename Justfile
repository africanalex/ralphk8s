# Justfile for Ralph K8s

# Default values
RELEASE_NAME := "ralph"
NAMESPACE := "ralph"
VALUES_FILE := ".helm/values.yaml"
CHART_DIR := ".helm"
REGISTRY := "192.168.88.252:32000"
IMAGE_NAME := "ralph-polyglot-base"
IMAGE_TAG := "latest"

# --- Main Commands ---

# Build and Push Docker Image
# Usage: just build
build:
    @echo "Building Docker image..."
    docker build -t {{REGISTRY}}/{{IMAGE_NAME}}:{{IMAGE_TAG}} .
    @echo "Pushing image to registry..."
    docker push {{REGISTRY}}/{{IMAGE_NAME}}:{{IMAGE_TAG}}

# Lint Helm Chart
# Usage: just helm-lint
helm-lint:
    @echo "Linting Helm chart..."
    helm lint {{CHART_DIR}}

# Install Helm Chart
# Usage: just helm-install
helm-install:
    @echo "Installing Helm chart..."
    helm install {{RELEASE_NAME}} {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        -f {{VALUES_FILE}}

# Upgrade Helm Chart
# Usage: just helm-upgrade
helm-upgrade:
    @echo "Upgrading Helm chart..."
    helm upgrade {{RELEASE_NAME}} {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        -f {{VALUES_FILE}}

# Template Helm Chart
# Usage: just helm-template [name]
helm-template *extra:
    @echo "Templating Helm chart..."
    helm template {{RELEASE_NAME}} {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        -f {{VALUES_FILE}} {{extra}}

# --- Kubernetes Commands ---

# Get all pods in the namespace
# Usage: just k-get-pods
k-get-pods:
    kubectl get pods -n {{NAMESPACE}}

# Get all services in the namespace
# Usage: just k-get-services
k-get-services:
    kubectl get services -n {{NAMESPACE}}

# Get all resources in the namespace
# Usage: just k-get-all
k-get-all:
    kubectl get all -n {{NAMESPACE}}

# Describe a pod
# Usage: just k-describe-pod <pod-name>
k-describe-pod pod:
    kubectl describe pod -n {{NAMESPACE}} {{pod}}

# Deploy Ralph Auth Pod (Run this first to login to AI providers)
auth:
    @echo "Deploying auth pod..."
    helm upgrade --install {{RELEASE_NAME}}-auth {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        --set job.name={{RELEASE_NAME}}-auth \
        --set job.project=auth \
        --set enableAuth=true \
        --set enableJob=false \
        -f {{VALUES_FILE}} \
        --wait
    @echo "Waiting for pod to be ready..."
    kubectl wait --for=condition=ready pod/{{RELEASE_NAME}}-auth -n {{NAMESPACE}}
    @echo "Entering auth shell... Run 'claude login' or 'gemini login', then 'exit'."
    kubectl exec -it {{RELEASE_NAME}}-auth -n {{NAMESPACE}} -- bash
    @echo "Cleaning up auth release..."
    helm uninstall {{RELEASE_NAME}}-auth -n {{NAMESPACE}}

# Start a Ralph Job using a project specific values file
# Usage: just start <name>
# Example: just start coe-docs (uses coe-docs-values.yaml)
start name:
    @echo "Starting Ralph Ralph job for {{name}} using {{name}}-values.yaml..."
    helm upgrade --install {{RELEASE_NAME}}-{{name}} {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        --set enableAuth=false \
        -f {{VALUES_FILE}} \
        -f {{name}}-values.yaml

# Cleanup a repository workspace (Rescue changes & Reset)
# Usage: just cleanup <name>
# Example: just cleanup coe-docs (uses coe-docs-values.yaml)
cleanup name:
    @echo "Starting cleanup job for {{name}}..."
    # We use 'helm template' piped to kubectl to force a manual run of the hook job
    helm template {{RELEASE_NAME}}-{{name}} {{CHART_DIR}} \
        -n {{NAMESPACE}} \
        --show-only templates/job-cleanup.yaml \
        --set enableCleanup=true \
        -f {{VALUES_FILE}} \
        -f {{name}}-values.yaml | kubectl apply -f -
    @echo "Cleanup job submitted. Waiting for logs..."
    kubectl wait --for=condition=ready pod -l app=ralph-cleanup,project={{name}} -n {{NAMESPACE}} --timeout=60s
    kubectl logs -l app=ralph-cleanup,project={{name}} -n {{NAMESPACE}} -f

# Follow logs for a running Ralph job
# Usage: just logs <name>
logs name:
    kubectl logs -l app=ralph,project={{name}} -n {{NAMESPACE}} -f --max-log-requests=20

# Delete a Ralph job
# Usage: just stop <name>
stop name:
    helm uninstall {{RELEASE_NAME}}-{{name}} -n {{NAMESPACE}}

# Debug: Shell into a running Ralph job (if active)
# Usage: just debug <name>
debug name:
    kubectl exec -it -l app=ralph,project={{name}} -n {{NAMESPACE}} -- bash

# List all Ralph jobs
list:
    helm list -n {{NAMESPACE}} --filter "{{RELEASE_NAME}}.*"
    @echo ""
    kubectl get jobs -n {{NAMESPACE}} -l managed-by=ralph