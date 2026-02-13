## Repository Context

This repo contains a Helm chart for deploying the Ralph Loop system (an
AI-driven automation job) to Kubernetes. The chart lives under `.helm/` with
templates in `.helm/templates/`, and it expects a prebuilt Docker image, a Git
repo to clone via SSH, an SSH key secret (default `git-ssh-key`), and a PVC for
session data.

## Instructions for Coding Agents

- Do not use `helpers.tpl`.
