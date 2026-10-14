/**
 * The wire protocol between the hosted Good Machines API and an app's own
 * server. The API calls the app's server for capabilities registered with
 * runsOn "app_server", always as one signed-in user of the app.
 *
 * Request: POST to the app server's URL with a JSON body (AgentRequest) and
 * `Authorization: Bearer <JWT>`. The JWT is signed by the API (EdDSA, keys at
 * <api>/v1/.well-known/jwks.json) and carries:
 *   iss  the API origin, e.g. https://agents.example.com
 *   aud  "gma:<projectId>"
 *   sub  the app's own user id (the `sub` of the token the app signed in with)
 *   env  "dev" or "prod"
 *   bh   base64url sha256 of the exact request body
 *   iat  when it was signed
 *   exp  set by the API; currently 60 seconds after iat
 *
 * Response: 200 with the JSON for the op (AgentResponse), or 4xx/5xx with
 * { error } in words the assistant may show the user.
 */
export declare const PROTOCOL_VERSION = 1;
export interface ObjectRef {
    objectId: string;
    objectRevision: number;
}
export type AgentRequest = 
/** A read or search: return the data the assistant asked for. */
{
    v: 1;
    op: "read";
    capability: string;
    input: unknown;
}
/**
 * Run an action once. operationId is stable across retries: store it with
 * the change atomically and return the same object if it was seen before.
 * It is opaque and contains ':'; idempotencyKeyFor (index.ts) turns it into
 * a header-safe key. No Idempotency-Key header is sent.
 */
 | {
    v: 1;
    op: "execute";
    capability: string;
    input: unknown;
    operationId: string;
}
/** Did this operation take effect? Return its object, or null. */
 | {
    v: 1;
    op: "lookup";
    capability: string;
    operationId: string;
}
/** Undo it, if the object is still at this revision. */
 | {
    v: 1;
    op: "compensate";
    capability: string;
    operationId: string;
    ref: ObjectRef;
}
/**
 * Deliver a notification to this user through the app's own channel (its
 * push setup). Sent only when the project has no APNs key with us.
 */
 | {
    v: 1;
    op: "notify";
    notification: AgentNotification;
};
export interface AgentNotification {
    notificationId: string;
    title: string;
    body: string;
    /** Open this chat when the user taps the notification. */
    conversationId?: string;
}
export type AgentResponse = {
    output: unknown;
} | {
    ref: ObjectRef;
} | {
    ref: ObjectRef | null;
} | {
    ok: true;
} | {
    ok: false;
    reason: string;
} | {
    delivered: boolean;
};
/**
 * Events the app's server sends us: POST <api>/v1/server/events with
 * `Authorization: Bearer <server key>` and this body.
 */
export interface ServerEvent {
    /** The app's own user id the event is for. */
    userId: string;
    /** A registered event capability's name. */
    type: string;
    /** The app's own id for this event; a resend with the same id is ignored. */
    eventId: string;
    payload?: Record<string, unknown>;
}
export declare const audienceFor: (projectId: string) => string;
