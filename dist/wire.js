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
export const PROTOCOL_VERSION = 1;
export const audienceFor = (projectId) => `gma:${projectId}`;
