import "server-only";
import { createLongplayServer } from "@tinkerlandai/longplay-sdk/server";
import { z } from "zod";
import { AppError } from "@/shared/errors/app-error";

const settings = z.object({
  baseUrl: z.url(), key: z.string().min(1), app: z.string().min(1),
  environment: z.enum(["sandbox", "live"]), feature: z.uuid(),
});

/** Optional hosted-organization access; mock and user-supplied connections remain independent. */
export async function withOrganizationAccess<T>(
  input: { workspaceId: string; provider: string; ownConnection: boolean },
  organize: () => Promise<T>,
  env: Record<string, string | undefined> = process.env,
): Promise<T> {
  if (!env.LONGPLAY_AI_ACCESS_FEATURE_ID || input.provider === "mock" || input.ownConnection) return organize();
  let allowed: boolean;
  try {
    const config = settings.parse({ baseUrl: env.LONGPLAY_BASE_URL, key: env.LONGPLAY_SECRET_KEY, app: env.LONGPLAY_APP_ID, environment: env.LONGPLAY_ENVIRONMENT, feature: env.LONGPLAY_AI_ACCESS_FEATURE_ID });
    if (!input.workspaceId) throw new Error("Missing trusted workspace");
    const client = createLongplayServer({ baseUrl: config.baseUrl, apiKey: config.key, scope: { projectId: config.app, environment: config.environment }, timeoutMs: 5000 });
    const { customer } = await client.getOrCreateCustomer({ externalUserId: `knowtrace:workspace:${input.workspaceId}` });
    const { check } = await client.checkEntitlement({ customerId: customer.id, requirement: { internal_feature_id: config.feature, quantity: "1", properties: {} } });
    if (check.kind !== "access") throw new Error("An access Feature is required");
    allowed = check.allowed;
  } catch {
    throw new AppError("AI_ACCESS_UNAVAILABLE", "暂时无法验证工作区的 AI 整理权限，请稍后重试。");
  }
  if (!allowed) throw new AppError("AI_PLAN_REQUIRED", "当前工作区的套餐不包含托管 AI 整理，请联系工作区管理员。");
  return organize();
}
