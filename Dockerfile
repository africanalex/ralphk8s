# Use a base image that supports multiple runtimes
FROM ubuntu:24.04

# Set environment variables for non-interactive installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system tools and dependencies
# Using the robust apt-get logic from your working Dockerfile
RUN set -eux; \
    if ! apt-get update; then \
        apt-get -o Acquire::AllowInsecureRepositories=true \
                -o Acquire::AllowDowngradeToInsecureRepositories=true update; \
        apt-get install -y --no-install-recommends ubuntu-keyring ca-certificates; \
    fi; \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        openssh-client \
        jq \
        build-essential \
        unzip \
        vim \
        bash \
        grep \
        sed \
        gawk \
        coreutils \
        time \
        # Polyglot Runtimes
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install GraalVM JDK 21                                                      
ENV JAVA_HOME=/opt/graalvm                                                    
ENV PATH="${JAVA_HOME}/bin:${PATH}"                                           
RUN curl -fsSL https://download.oracle.com/graalvm/21/latest/graalvm-jdk-21_linux-x64_bin.tar.gz \                                                          
    | tar -xz -C /opt \                                                       
    && mv /opt/graalvm-jdk-* /opt/graalvm   

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Gemini CLI globally
RUN npm install -g @google/gemini-cli

# Setup workspace and directories
# Ubuntu 24.04 already has the 'ubuntu' user (UID 1000)
RUN mkdir -p /work /etc/ralph /app && \
    chown -R ubuntu:ubuntu /work /etc/ralph /app

WORKDIR /work

# Switch to non-root user
USER ubuntu

# Install Bun as the ubuntu user
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/home/ubuntu/.bun/bin:${PATH}"

# Install Claude CLI as the ubuntu user
RUN curl -fsSL https://claude.ai/install.sh | bash

# Set PATH to include user's local bin
ENV PATH="/home/ubuntu/.local/bin:${PATH}"

# Verify installations
RUN python3 --version && \
    node --version && \
    npm --version && \
    bun --version && \
    java -version && \
    git --version && \
    claude --version

ENTRYPOINT ["bash"]