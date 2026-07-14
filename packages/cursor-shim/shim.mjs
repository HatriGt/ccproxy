#!/usr/bin/env node
/**
 * Cursor + Codex ↔ CLIProxyAPI gateway.
 *
 * Cursor Agent sends Anthropic-native messages (tool_use / tool_result blocks) to
 * OpenAI /v1/chat/completions. CLIProxyAPI's OpenAI translator rejects those.
 * This shim converts them to OpenAI tool format before forwarding upstream.
 *
 * Codex uses POST /v1/responses on the same public URL; those requests are
 * proxied through unchanged (plus GET /v1/models and other non-chat paths).
 */

import http from "node:http";
import { URL } from "node:url";

const SHIM_HOST = process.env.CURSOR_SHIM_HOST || "127.0.0.1";
const SHIM_PORT = Number(process.env.CURSOR_SHIM_PORT || 8320);
const UPSTREAM = process.env.CLIPROXY_UPSTREAM || "http://127.0.0.1:8318";

const ANTHROPIC_BLOCK_TYPES = new Set([
  "text",
  "tool_use",
  "tool_result",
  "image",
  "thinking",
  "redacted_thinking",
]);

/**
 * @param {unknown} content
 * @returns {boolean}
 */
function isAnthropicContent(content) {
  return (
    Array.isArray(content) &&
    content.some(
      (block) =>
        block &&
        typeof block === "object" &&
        ANTHROPIC_BLOCK_TYPES.has(/** @type {{type?: string}} */ (block).type)
    )
  );
}

/**
 * @param {unknown} content
 * @returns {string}
 */
function flattenToolResultContent(content) {
  if (typeof content === "string") {
    return content;
  }
  if (!Array.isArray(content)) {
    return JSON.stringify(content ?? "");
  }
  return content
    .map((block) => {
      if (!block || typeof block !== "object") {
        return "";
      }
      if (block.type === "text") {
        return block.text || "";
      }
      return JSON.stringify(block);
    })
    .filter(Boolean)
    .join("\n\n");
}

/**
 * @param {Array<Record<string, unknown>>} tools
 * @returns {Array<Record<string, unknown>>}
 */
function convertTools(tools) {
  if (!Array.isArray(tools) || tools.length === 0) {
    return tools;
  }
  if (tools[0]?.type === "function") {
    return tools;
  }
  if (!tools[0]?.name) {
    return tools;
  }
  return tools.map((tool) => ({
    type: "function",
    function: {
      name: tool.name,
      description: tool.description,
      parameters: tool.input_schema || { type: "object", properties: {} },
    },
  }));
}

/**
 * @param {Array<Record<string, unknown>>} messages
 * @returns {Array<Record<string, unknown>>}
 */
function convertMessages(messages) {
  /** @type {Array<Record<string, unknown>>} */
  const out = [];

  for (const msg of messages) {
    const role = msg.role;
    const content = msg.content;

    if (!isAnthropicContent(content)) {
      out.push(msg);
      continue;
    }

    /** @type {Array<Record<string, unknown>>} */
    const blocks = /** @type {Array<Record<string, unknown>>} */ (content);

    if (role === "user") {
      const textParts = [];
      const toolResults = [];

      for (const block of blocks) {
        if (block.type === "text" && typeof block.text === "string" && block.text.trim()) {
          textParts.push(block.text);
        } else if (block.type === "tool_result") {
          toolResults.push(block);
        }
      }

      for (const tr of toolResults) {
        out.push({
          role: "tool",
          tool_call_id: tr.tool_use_id,
          content: flattenToolResultContent(tr.content),
        });
      }

      if (textParts.length > 0) {
        out.push({ role: "user", content: textParts.join("\n") });
      }
      continue;
    }

    if (role === "assistant") {
      const textParts = [];
      const toolUses = [];

      for (const block of blocks) {
        if (block.type === "text" && typeof block.text === "string" && block.text) {
          textParts.push(block.text);
        } else if (block.type === "tool_use") {
          toolUses.push(block);
        }
      }

      /** @type {Record<string, unknown>} */
      const assistant = {
        role: "assistant",
        content: textParts.join("") || (toolUses.length > 0 ? "" : null),
      };

      if (toolUses.length > 0) {
        assistant.tool_calls = toolUses.map((tu) => ({
          id: tu.id,
          type: "function",
          function: {
            name: tu.name,
            arguments: JSON.stringify(tu.input ?? {}),
          },
        }));
      }

      out.push(assistant);
      continue;
    }

    out.push(msg);
  }

  return out;
}

/**
 * @param {Record<string, unknown>} body
 * @returns {boolean}
 */
function needsConversion(body) {
  if (Array.isArray(body.messages)) {
    return body.messages.some((m) => isAnthropicContent(m?.content));
  }
  if (Array.isArray(body.tools) && body.tools[0]?.name && !body.tools[0]?.type) {
    return true;
  }
  return false;
}

/**
 * @param {Record<string, unknown>} body
 * @returns {Record<string, unknown>}
 */
function convertRequestBody(body) {
  const next = { ...body };
  if (Array.isArray(body.messages)) {
    next.messages = convertMessages(/** @type {Array<Record<string, unknown>>} */ (body.messages));
  }
  if (Array.isArray(body.tools)) {
    next.tools = convertTools(/** @type {Array<Record<string, unknown>>} */ (body.tools));
  }
  return next;
}

/**
 * @param {import("node:http").IncomingMessage} req
 * @returns {Promise<Buffer>}
 */
function readBody(req) {
  return new Promise((resolve, reject) => {
    /** @type {Buffer[]} */
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/**
 * @param {import("node:http").IncomingMessage} clientReq
 * @param {import("node:http").ServerResponse} clientRes
 * @param {string} targetPath
 * @param {Buffer|undefined} body
 */
function proxyRequest(clientReq, clientRes, targetPath, body) {
  const upstreamUrl = new URL(targetPath, UPSTREAM);
  const headers = { ...clientReq.headers, host: upstreamUrl.host };
  delete headers["content-length"];
  if (body) {
    headers["content-length"] = String(body.length);
  }

  const upstreamReq = http.request(
    {
      hostname: upstreamUrl.hostname,
      port: upstreamUrl.port || 80,
      path: upstreamUrl.pathname + upstreamUrl.search,
      method: clientReq.method,
      headers,
    },
    (upstreamRes) => {
      clientRes.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
      upstreamRes.pipe(clientRes);
    }
  );

  upstreamReq.on("error", (err) => {
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "content-type": "application/json" });
      clientRes.end(JSON.stringify({ error: { message: String(err.message) } }));
      return;
    }
    clientRes.end();
  });

  if (body && body.length > 0) {
    upstreamReq.write(body);
  }
  upstreamReq.end();
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || "/", `http://${SHIM_HOST}:${SHIM_PORT}`);

  if (req.method === "GET" && url.pathname === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, upstream: UPSTREAM }));
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/chat/completions") {
    try {
      const raw = await readBody(req);
      let bodyBuf = raw;

      if (raw.length > 0) {
        const parsed = JSON.parse(raw.toString("utf8"));
        if (needsConversion(parsed)) {
          const converted = convertRequestBody(parsed);
          bodyBuf = Buffer.from(JSON.stringify(converted), "utf8");
        }
      }

      proxyRequest(req, res, url.pathname + url.search, bodyBuf);
      return;
    } catch (err) {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: `Shim parse error: ${err.message}` } }));
      return;
    }
  }

  const raw = req.method === "GET" || req.method === "HEAD" ? undefined : await readBody(req);
  proxyRequest(req, res, url.pathname + url.search, raw);
});

server.listen(SHIM_PORT, SHIM_HOST, () => {
  console.log(`cursor-shim listening on http://${SHIM_HOST}:${SHIM_PORT}`);
  console.log(`upstream: ${UPSTREAM}`);
});
