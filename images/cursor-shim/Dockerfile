FROM node:22-alpine

WORKDIR /app

COPY packages/cursor-shim/shim.mjs ./shim.mjs

ENV CURSOR_SHIM_HOST=0.0.0.0
ENV CURSOR_SHIM_PORT=8320
ENV CLIPROXY_UPSTREAM=http://cli-proxy-api:8318

EXPOSE 8320

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- "http://127.0.0.1:8320/health" >/dev/null || exit 1

CMD ["node", "shim.mjs"]
