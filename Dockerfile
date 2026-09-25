# AI SRE - Self-Healing Toolbox Container
# Multi-stage build for security
FROM alpine:3.22 AS builder

LABEL maintainer="AI-SRE Team"
LABEL description="Lean CLI toolbox container for Kubernetes operations via N8N"
LABEL version="2.1.5"

# Update package index and install base system packages
RUN apk update && apk upgrade && apk add --no-cache \
    # Core utilities
    curl wget git openssh-client \
    bash zsh coreutils findutils \
    grep sed gawk tree \
    # Python for MCP Server
    python3 py3-pip \
    # Processing tools
    jq yq \
    # Network tools
    bind-tools netcat-openbsd \
    # SSL support for Helm
    openssl \
    # Security updates
    ca-certificates \
    # Build tools for compiling Node.js from source
    build-base linux-headers

# Install kubectl
ARG KUBECTL_VERSION=v1.36.5
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; fi && \
    if [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/ && \
    kubectl version --client

# Install Helm
ARG HELM_VERSION=v3.22.0
RUN curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    && chmod 700 get_helm.sh \
    && VERIFY_CHECKSUM=false ./get_helm.sh --version ${HELM_VERSION} \
    && rm get_helm.sh

# Install Flux CLI v2
ARG FLUX_VERSION=2.9.5
RUN curl -s https://fluxcd.io/install.sh | bash

# Install GitHub CLI
RUN apk add --no-cache github-cli

# Install mise (modern runtime version manager)
RUN curl https://mise.run | sh && \
    mv ~/.local/bin/mise /usr/local/bin/mise

# Node.js is NOT built via mise any more: on musl, mise compiles node from
# source (~1h per arch in CI), and a compiled-in node never receives distro
# security updates. The runtime stage installs Alpine's nodejs/npm packages
# instead, which `apk upgrade` keeps current on every rebuild.

# Install Python packages for MCP Server
RUN apk add --no-cache \
    py3-aiohttp \
    py3-yaml \
    py3-dotenv

# Create application directory structure
RUN mkdir -p /app/src \
    /app/scripts \
    /app/logs \
    /app/work \
    /app/k8s-repo

# Copy application files
COPY src/mcp_server_protocol.py /app/src/
COPY scripts/entrypoint.sh /app/scripts/

# Make scripts executable and secure
RUN chmod +x /app/scripts/*.sh && \
    chmod 755 /app/src/mcp_server_protocol.py

# Final runtime stage - minimal Alpine image
FROM alpine:3.22

# Install only runtime dependencies and essential tools
RUN apk update && apk upgrade && apk add --no-cache \
    python3 \
    py3-aiohttp \
    py3-yaml \
    py3-dotenv \
    ca-certificates \
    # Essential tools for runtime
    bash \
    curl \
    wget \
    git \
    jq \
    yq \
    grep \
    sed \
    gawk \
    tree \
    findutils \
    netcat-openbsd \
    github-cli \
    nodejs \
    npm \
    && rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copy only the essential binaries from builder stage
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/
COPY --from=builder /usr/local/bin/helm /usr/local/bin/
COPY --from=builder /usr/local/bin/flux /usr/local/bin/

# Copy mise from builder stage (node comes from apk, see above)
COPY --from=builder /usr/local/bin/mise /usr/local/bin/

# Copy application files from builder stage
COPY --from=builder /app /app

# Set working directory
WORKDIR /app

# Create non-root user for running the application
RUN addgroup -g 1000 aisre && \
    adduser -D -u 1000 -G aisre aisre && \
    chown -R aisre:aisre /app

# Switch to non-root user
USER aisre

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider http://localhost:8080/health || exit 1

# Default environment variables
ENV AGENT_MODE=executor \
    AGENT_LOG_LEVEL=INFO \
    MCP_SERVER_PORT=8080 \
    PYTHONUNBUFFERED=1 \
    MISE_DATA_DIR=/usr/local/share/mise \
    MISE_CACHE_DIR=/usr/local/share/mise/cache

# Entry point
ENTRYPOINT ["/app/scripts/entrypoint.sh"]

# Default command - run MCP protocol server
CMD ["python3", "/app/src/mcp_server_protocol.py"]
