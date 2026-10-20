import type { Metadata } from "next";
import { headers } from "next/headers";
import { connection } from "next/server";

import { listCategories } from "@/features/capture/queries";
import { AppShell } from "@/components/app-shell";
import { currentDataAccessScope } from "@/features/auth/access";
import { isAuthEnabled } from "@/features/auth/go-user-system";
import { listActorWorkspaces } from "@/features/workspace/service";

import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://knowtrace-workflow.vercel.app"),
  title: {
    default: "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
    template: "%s · KnowTrace-Workflow",
  },
  description:
    "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
  keywords: [
    "KnowTrace",
    "KnowTrace-Workflow",
    "认知溯源",
    "知识管理",
    "可审阅工作流",
    "证据链核验",
    "RBAC 多租户",
    "工程审计",
    "AI 知识管理",
  ],
  openGraph: {
    title: "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
    description:
      "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
    url: "https://knowtrace-workflow.vercel.app",
    siteName: "KnowTrace-Workflow",
    locale: "zh_CN",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "KnowTrace-Workflow · 面向 AI 时代的认知溯源与可审阅知识管理系统",
    description:
      "面向 AI 时代的认知溯源与可审阅知识管理工作流系统。把散碎输入变成可追溯、可审阅的知识记录，支持端到端证据链核验、RBAC 多租户权限与全生命周期工程审计。",
  },
  robots: {
    index: true,
    follow: true,
  },
};

export default async function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const requestHeaders = await headers();
  const authEnabled = isAuthEnabled();
  const authPage = requestHeaders.get("x-knowtrace-workflow-auth-page") === "1";
  const userId = requestHeaders.get("x-knowtrace-workflow-user-id");
  const user = userId
    ? {
        id: Number(userId),
        username: decodeURIComponent(
          requestHeaders.get("x-knowtrace-workflow-username") ?? "",
        ),
        nickname: decodeURIComponent(
          requestHeaders.get("x-knowtrace-workflow-nickname") ?? "",
        ),
      }
    : null;

  if (authEnabled && (authPage || !user)) {
    return (
      <html lang="zh-CN">
        <body>{children}</body>
      </html>
    );
  }

  await connection();
  const scope = await currentDataAccessScope();
  const [categories, workspaces] = await Promise.all([
    listCategories(),
    listActorWorkspaces(scope.actorId),
  ]);

  return (
    <html lang="zh-CN">
      <body>
        <AppShell
          categories={categories}
          currentWorkspaceId={scope.workspaceId}
          user={user}
          workspaces={workspaces}
        >
          {children}
        </AppShell>
      </body>
    </html>
  );
}
