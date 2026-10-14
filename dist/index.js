import { createHash } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { audienceFor } from "./wire.js";
export * from "./wire.js";
// A header-safe key for an operation: lowercase hex SHA-256 of the operationId
// ("undo" hashes "undo\0" + operationId, so Undo never reuses the original
// key). The derivation is fixed; the Swift SDK's AgentOperation gives the same value.
export function idempotencyKeyFor(operationId, purpose = "execute") {
    return createHash("sha256").update(purpose === "undo" ? "undo\u0000" + operationId : operationId, "utf8").digest("hex");
}
// Thrown by a handler to send the assistant a reason it may tell the user.
export class AgentCallError extends Error {
    status;
    constructor(message, status = 400) {
        super(message);
        this.status = status;
    }
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const origin = (url) => url.replace(/\/+$/, "");
// Checks that a request came from the hosted API for this project, untouched,
// and returns the user it acts for. Use it directly if you route calls yourself.
export async function verifyAgentRequest(req, opts) {
    const header = req.headers.get("authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!token)
        throw new AgentCallError("Missing signature.", 401);
    const raw = await req.text();
    let claims;
    try {
        const keys = opts.keySet ?? remoteKeys(`${origin(opts.apiUrl)}/v1/.well-known/jwks.json`);
        ({ payload: claims } = await jwtVerify(token, keys, {
            issuer: origin(opts.apiUrl),
            audience: audienceFor(opts.projectId),
            algorithms: ["EdDSA"],
            // exp (set by the API, currently 60s) is always enforced; this is a
            // separate upper bound on age since iat, and requires iat to be present.
            maxTokenAge: "5m",
        }));
    }
    catch {
        throw new AgentCallError("Bad signature.", 401);
    }
    if (claims.bh !== createHash("sha256").update(raw).digest("base64url"))
        throw new AgentCallError("Body doesn't match the signature.", 401);
    const environment = claims.env === "prod" ? "prod" : "dev";
    if (opts.environments && !opts.environments.includes(environment))
        throw new AgentCallError(`This server doesn't answer ${environment} calls.`, 403);
    if (typeof claims.sub !== "string" || !claims.sub)
        throw new AgentCallError("No user.", 401);
    let request;
    try {
        request = JSON.parse(raw);
    }
    catch {
        throw new AgentCallError("Bad request body.");
    }
    return { ctx: { userId: claims.sub, environment }, request };
}
const remoteSets = new Map();
function remoteKeys(url) {
    let set = remoteSets.get(url);
    if (!set)
        remoteSets.set(url, (set = createRemoteJWKSet(new URL(url))));
    return set;
}
export function createAgentHandler(opts) {
    const reads = opts.reads ?? {};
    const actions = opts.actions ?? {};
    return async (req) => {
        try {
            if (req.method !== "POST")
                return json({ error: "Use POST." }, 405);
            const { ctx, request: r } = await verifyAgentRequest(req, opts);
            if (r.op === "read") {
                const read = Object.hasOwn(reads, r.capability) ? reads[r.capability] : undefined;
                if (!read)
                    return json({ error: `No read named ${r.capability} on this server.` }, 404);
                return json({ output: (await read(r.input, ctx)) ?? null });
            }
            if (r.op === "notify") {
                if (!opts.notify)
                    return json({ error: "This server doesn't deliver notifications." }, 404);
                await opts.notify(r.notification, ctx);
                return json({ delivered: true });
            }
            const action = Object.hasOwn(actions, r.capability) ? actions[r.capability] : undefined;
            if (!action)
                return json({ error: `No action named ${r.capability} on this server.` }, 404);
            const at = { ...ctx, operationId: r.operationId, idempotencyKey: idempotencyKeyFor(r.operationId) };
            if (r.op === "execute")
                return json({ ref: await action.execute(r.input, at) });
            if (r.op === "lookup")
                return json({ ref: (await action.lookup(at)) ?? null });
            if (r.op === "compensate") {
                if (!action.compensate)
                    return json({ ok: false, reason: "This action can't be undone." });
                return json(await action.compensate(r.ref, at));
            }
            return json({ error: "Unknown operation." }, 400);
        }
        catch (e) {
            if (e instanceof AgentCallError)
                return json({ error: e.message }, e.status);
            // Never echo internal errors: they can carry other users' data.
            console.error("good machines agent call failed", e instanceof Error ? e.name : typeof e);
            return json({ error: "The app's server couldn't do that." }, 500);
        }
    };
}
// Calls from the app's server to the hosted API.
export function createAgentClient(opts) {
    const doFetch = opts.fetch ?? fetch;
    return {
        // Tells the assistant something happened for one user, e.g. a new
        // transaction. Alerts the user set up in chat run when their conditions match.
        async sendEvent(event) {
            const res = await doFetch(`${origin(opts.apiUrl)}/v1/server/events`, {
                method: "POST",
                headers: { "content-type": "application/json", authorization: `Bearer ${opts.serverKey}` },
                body: JSON.stringify(event),
            });
            const body = (await res.json().catch(() => ({})));
            if (!res.ok)
                throw new AgentCallError(body.error ?? `The API refused the event (${res.status}).`, res.status);
            return body;
        },
    };
}
