import { type JWTVerifyGetKey } from "jose";
import { type AgentNotification, type AgentRequest, type ObjectRef, type ServerEvent } from "./wire.js";
export * from "./wire.js";
export interface AgentCallContext {
    userId: string;
    environment: "dev" | "prod";
}
export type ReadHandler = (input: any, ctx: AgentCallContext) => Promise<unknown> | unknown;
export interface ActionContext extends AgentCallContext {
    operationId: string;
    idempotencyKey: string;
}
export interface ActionHandler {
    execute(input: any, ctx: ActionContext): Promise<ObjectRef> | ObjectRef;
    lookup(ctx: ActionContext): Promise<ObjectRef | null> | ObjectRef | null;
    compensate?(ref: ObjectRef, ctx: ActionContext): Promise<{
        ok: true;
    } | {
        ok: false;
        reason: string;
    }>;
}
export declare function idempotencyKeyFor(operationId: string, purpose?: "execute" | "undo"): string;
export interface AgentHandlerOptions {
    projectId: string;
    apiUrl: string;
    reads?: Record<string, ReadHandler>;
    actions?: Record<string, ActionHandler>;
    notify?: (n: AgentNotification, ctx: AgentCallContext) => Promise<void> | void;
    environments?: Array<"dev" | "prod">;
    keySet?: JWTVerifyGetKey;
}
export declare class AgentCallError extends Error {
    readonly status: number;
    constructor(message: string, status?: number);
}
export interface VerifiedCall {
    ctx: AgentCallContext;
    request: AgentRequest;
}
export declare function verifyAgentRequest(req: Request, opts: Pick<AgentHandlerOptions, "projectId" | "apiUrl" | "keySet" | "environments">): Promise<VerifiedCall>;
export declare function createAgentHandler(opts: AgentHandlerOptions): (req: Request) => Promise<Response>;
export interface AgentClientOptions {
    apiUrl: string;
    serverKey: string;
    fetch?: typeof fetch;
}
export declare function createAgentClient(opts: AgentClientOptions): {
    sendEvent(event: ServerEvent): Promise<{
        accepted: boolean;
        duplicate: boolean;
        queuedRuns: number;
    }>;
};
