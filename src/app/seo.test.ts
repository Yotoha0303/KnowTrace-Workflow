import { describe, expect, it, vi } from "vitest";

vi.mock("@/server/db/client", () => ({
  db: {},
  sqlClient: {},
}));

import robots from "./robots";
import sitemap from "./sitemap";
import { metadata } from "./layout";

describe("SEO metadata and routing configuration", () => {
  describe("robots()", () => {
    it("returns correct crawlers rules and sitemap URL", () => {
      const config = robots();
      expect(config.sitemap).toBe(
        "https://knowtrace-workflow.vercel.app/sitemap.xml",
      );
      expect(config.rules).toEqual({
        userAgent: "*",
        allow: ["/", "/login"],
        disallow: ["/api/", "/account/", "/data-transfer/"],
      });
    });
  });

  describe("sitemap()", () => {
    it("returns public endpoints with valid properties", () => {
      const entries = sitemap();
      expect(entries).toHaveLength(3);

      const urls = entries.map((entry) => entry.url);
      expect(urls).toEqual([
        "https://knowtrace-workflow.vercel.app",
        "https://knowtrace-workflow.vercel.app/login",
        "https://knowtrace-workflow.vercel.app/search",
      ]);

      const rootEntry = entries.find(
        (entry) => entry.url === "https://knowtrace-workflow.vercel.app",
      );
      expect(rootEntry).toMatchObject({
        url: "https://knowtrace-workflow.vercel.app",
        priority: 1.0,
        changeFrequency: "daily",
      });
      expect(rootEntry?.lastModified).toBeInstanceOf(Date);

      const loginEntry = entries.find(
        (entry) => entry.url === "https://knowtrace-workflow.vercel.app/login",
      );
      expect(loginEntry).toMatchObject({
        url: "https://knowtrace-workflow.vercel.app/login",
        priority: 0.8,
        changeFrequency: "monthly",
      });
      expect(loginEntry?.lastModified).toBeInstanceOf(Date);

      const searchEntry = entries.find(
        (entry) => entry.url === "https://knowtrace-workflow.vercel.app/search",
      );
      expect(searchEntry).toMatchObject({
        url: "https://knowtrace-workflow.vercel.app/search",
        priority: 0.5,
        changeFrequency: "weekly",
      });
      expect(searchEntry?.lastModified).toBeInstanceOf(Date);
    });
  });

  describe("layout metadata", () => {
    it("defines base URL, rich titles, descriptions and social cards", () => {
      expect(metadata.metadataBase?.toString()).toBe(
        "https://knowtrace-workflow.vercel.app/",
      );
      expect(metadata.title).toEqual({
        default:
          "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
        template: "%s · KnowTrace-Workflow",
      });
      expect(metadata.description).toBe(
        "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
      );
      expect(metadata.keywords).toEqual(
        expect.arrayContaining(["KnowTrace", "认知溯源", "可审阅工作流"]),
      );

      expect(metadata.openGraph).toMatchObject({
        title: "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
        description:
          "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
        url: "https://knowtrace-workflow.vercel.app",
        siteName: "KnowTrace-Workflow",
        locale: "zh_CN",
        type: "website",
      });

      expect(metadata.twitter).toMatchObject({
        card: "summary_large_image",
        title: "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
        description:
          "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
      });

      expect(metadata.robots).toEqual({
        index: true,
        follow: true,
      });
    });
  });
});
