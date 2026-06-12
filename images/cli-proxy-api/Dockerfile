# Pinned upstream CLIProxyAPI — OAuth + Claude via subscription login.
ARG CLIPROXY_UPSTREAM_TAG=v7.1.63
FROM eceasy/cli-proxy-api:${CLIPROXY_UPSTREAM_TAG}

COPY config/config.yaml /CLIProxyAPI/config.yaml

# Auth tokens persisted via compose volume at /data/auth (see config.yaml auth-dir).
