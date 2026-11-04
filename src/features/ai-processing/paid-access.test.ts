import { beforeEach, expect, it, vi } from "vitest";
import { withOrganizationAccess } from "./paid-access";
const api = vi.hoisted(() => ({ customer: vi.fn(), check: vi.fn(), create: vi.fn() }));
vi.mock("@tinkerlandai/longplay-sdk/server", () => ({ createLongplayServer: api.create }));
const env = { LONGPLAY_AI_ACCESS_FEATURE_ID: "11111111-1111-4111-8111-111111111111", LONGPLAY_BASE_URL: "https://billing.example", LONGPLAY_SECRET_KEY: "private", LONGPLAY_APP_ID: "app", LONGPLAY_ENVIRONMENT: "sandbox" };
const input = { workspaceId: "trusted-workspace", provider: "openai", ownConnection: false };
beforeEach(() => {
  vi.clearAllMocks();
  api.create.mockReturnValue({ getOrCreateCustomer: api.customer, checkEntitlement: api.check });
  api.customer.mockResolvedValue({ customer: { id: "customer" } });
  api.check.mockResolvedValue({ check: { allowed: true, kind: "access" } });
});
it.each([{ ...input, provider: "mock" }, { ...input, ownConnection: true }])("keeps local/BYOK calls outside hosted billing", async (request) => {
  await expect(withOrganizationAccess(request, async () => "ok", env)).resolves.toBe("ok");
  expect(api.create).not.toHaveBeenCalled();
});
it("is disabled without its feature configuration", async () => {
  await expect(withOrganizationAccess(input, async () => "ok", {})).resolves.toBe("ok");
  expect(api.create).not.toHaveBeenCalled();
});
it("checks the server-resolved workspace without sending its records or API key", async () => {
  await expect(withOrganizationAccess(input, async () => "result", env)).resolves.toBe("result");
  expect(api.customer).toHaveBeenCalledWith({ externalUserId: "knowtrace:workspace:trusted-workspace" });
  expect(api.check).toHaveBeenCalledWith({ customerId: "customer", requirement: { internal_feature_id: env.LONGPLAY_AI_ACCESS_FEATURE_ID, quantity: "1", properties: {} } });
});
it("does not invoke AI after expiry/revocation and does not cache grants", async () => {
  const model = vi.fn(async () => "result");
  await withOrganizationAccess(input, model, env);
  api.check.mockResolvedValue({ check: { allowed: false, kind: "access" } });
  await expect(withOrganizationAccess(input, model, env)).rejects.toMatchObject({ code: "AI_PLAN_REQUIRED" });
  expect(model).toHaveBeenCalledTimes(1);
});
it("fails closed on errors or an inappropriate metered Feature", async () => {
  const model = vi.fn();
  api.check.mockRejectedValueOnce(new Error("private key"));
  await expect(withOrganizationAccess(input, model, env)).rejects.toMatchObject({ code: "AI_ACCESS_UNAVAILABLE" });
  api.check.mockResolvedValue({ check: { allowed: true, kind: "metered" } });
  await expect(withOrganizationAccess(input, model, env)).rejects.toMatchObject({ code: "AI_ACCESS_UNAVAILABLE" });
  expect(model).not.toHaveBeenCalled();
});
