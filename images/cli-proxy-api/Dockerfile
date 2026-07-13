# Pinned upstream CLIProxyAPI — OAuth + Claude via subscription login.
ARG CLIPROXY_UPSTREAM_TAG=v7.2.71
FROM eceasy/cli-proxy-api:${CLIPROXY_UPSTREAM_TAG}

# Env-templated config + entrypoint that renders it at start (logging toggles
# come from .env; see images/cli-proxy-api/entrypoint.sh).
COPY config/config.yaml.template /CLIProxyAPI/config.yaml.template
COPY config/model-aliases.default.yaml /CLIProxyAPI/model-aliases.default.yaml
COPY images/cli-proxy-api/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Auth tokens persisted via compose volume at /data/auth (see config.yaml auth-dir).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
