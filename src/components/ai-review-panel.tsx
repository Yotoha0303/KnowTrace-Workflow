"use client";

import {
  useEffect,
  useMemo,
  useState,
  useSyncExternalStore,
  useTransition,
} from "react";
import { useRouter } from "next/navigation";
import {
  Bot,
  Check,
  CircleAlert,
  CircleCheck,
  FilePenLine,
  LoaderCircle,
  PlugZap,
  RotateCcw,
  Save,
  ShieldCheck,
  Sparkles,
  X,
} from "lucide-react";

import {
  auditClaimAction,
  decideSuggestionAction,
  detectCCSwitchAction,
  organizeCaptureAction,
  rollbackSuggestionAction,
  testCCSwitchCurrentProviderAction,
} from "@/app/actions";
import { DEFAULT_CC_SWITCH_BASE_URL } from "@/features/ai-processing/connection";
import { applySelectedContentSuggestions } from "@/features/ai-processing/content-edits";
import type { CaptureDetailDTO, CategoryDTO } from "@/features/capture/queries";
import { CONTENT_TYPE_LABELS, CONTENT_TYPES, type ContentType } from "@/features/capture/schema";

const statusLabels = {
  pending: "待审阅",
  accepted: "已接受",
  modified: "修改后接受",
  rejected: "已驳回",
  stale: "已过期",
  rolled_back: "已整体回退",
} as const;

const runStatusLabels = {
  running: "处理中",
  succeeded: "处理成功",
  failed: "处理失败",
  cancelled: "已取消",
} as const;

const auditCoverageLabels = {
  limited: "覆盖有限",
  moderate: "覆盖一般",
  broad: "覆盖较广",
} as const;

const auditBalanceLabels = {
  insufficient: "缺少方向性证据",
  one_sided: "证据方向单一",
  mixed: "包含正反证据",
} as const;

const auditAssessmentLabels = {
  supported: "倾向支持",
  refuted: "倾向反驳",
  inconclusive: "暂无法判断",
  needs_more_evidence: "需要更多证据",
} as const;

const auditFindingLabels = {
  source_quality: "来源质量",
  coverage_gap: "覆盖缺口",
  contradiction: "正反核对",
  falsifiability: "可证伪性",
  scope: "适用范围",
  freshness: "时效性",
} as const;

const AI_CREDENTIAL_SESSION_KEY = "knowtrace.ai-credentials.v1";

type AIProvider = "mock" | "openai" | "deepseek";
type OpenAIConnectionMode =
  | "api_key"
  | "ccswitch"
  | "ccswitch_auto"
  | "ccswitch_codex_oauth";

type CCSwitchConnectionStatus = {
  phase: "idle" | "checking" | "reachable" | "testing" | "ready" | "error";
  title: string;
  message: string;
};

type SessionCredentials = {
  openAIConnectionMode: OpenAIConnectionMode;
  openAIKey: string;
  openAIModel: string;
  ccSwitchCodexModel: string;
  ccSwitchBaseURL: string;
  ccSwitchToken: string;
  deepSeekKey: string;
  deepSeekModel: string;
};

const DEFAULT_SESSION_CREDENTIALS: SessionCredentials = {
  openAIConnectionMode: "ccswitch_auto",
  openAIKey: "",
  openAIModel: "",
  // 默认别名，非模型选择：CC-Switch Codex OAuth 路由要求 claude- 前缀，出站由 CC-Switch 转发。
  ccSwitchCodexModel: "claude-sonnet-4-5",
  ccSwitchBaseURL: DEFAULT_CC_SWITCH_BASE_URL,
  ccSwitchToken: "",
  deepSeekKey: "",
  deepSeekModel: "",
};

const AI_CREDENTIAL_EVENT = "knowtrace-ai-credentials-changed";

function subscribeCredentials(onStoreChange: () => void) {
  window.addEventListener(AI_CREDENTIAL_EVENT, onStoreChange);
  return () => window.removeEventListener(AI_CREDENTIAL_EVENT, onStoreChange);
}

function credentialsSnapshot() {
  return window.sessionStorage.getItem(AI_CREDENTIAL_SESSION_KEY);
}

function serverCredentialsSnapshot() {
  return null;
}

function parseCredentials(raw: string | null): SessionCredentials | null {
  if (!raw) return null;
  try {
    const value = JSON.parse(raw) as Partial<SessionCredentials>;
    return {
      openAIConnectionMode:
        value.openAIConnectionMode === "ccswitch" ||
        value.openAIConnectionMode === "ccswitch_codex_oauth"
            ? "ccswitch_auto"
          : value.openAIConnectionMode === "ccswitch_auto"
            ? value.openAIConnectionMode
          : value.openAIConnectionMode === "api_key"
            ? "api_key"
            : "ccswitch_auto",
      openAIKey: typeof value.openAIKey === "string" ? value.openAIKey : "",
      openAIModel: typeof value.openAIModel === "string" ? value.openAIModel : "",
      ccSwitchCodexModel:
        typeof value.ccSwitchCodexModel === "string"
          ? value.ccSwitchCodexModel
          : "claude-sonnet-4-5",
      ccSwitchBaseURL:
        typeof value.ccSwitchBaseURL === "string"
          ? value.ccSwitchBaseURL
          : DEFAULT_CC_SWITCH_BASE_URL,
      ccSwitchToken:
        typeof value.ccSwitchToken === "string" ? value.ccSwitchToken : "",
      deepSeekKey: typeof value.deepSeekKey === "string" ? value.deepSeekKey : "",
      deepSeekModel:
        typeof value.deepSeekModel === "string" ? value.deepSeekModel : "",
    };
  } catch {
    return null;
  }
}

function historyProviderLabel(provider: string): string {
  if (provider === "ccswitch-current-provider") return "CC-Switch · 当前供应商";
  if (provider === "openai-ccswitch") return "OpenAI · CC-Switch";
  if (provider === "ccswitch-codex-oauth") return "CC-Switch · Codex OAuth";
  if (provider === "openai") return "OpenAI";
  if (provider === "deepseek") return "DeepSeek";
  if (provider === "mock") return "本地规则";
  return provider;
}

export function AIReviewPanel({
  capture,
  categories,
  editorReady,
  hasUnsavedChanges,
}: {
  capture: CaptureDetailDTO;
  categories: CategoryDTO[];
  editorReady: boolean;
  hasUnsavedChanges: boolean;
}) {
  const router = useRouter();
  const [provider, setProvider] = useState<AIProvider>("mock");
  const savedCredentialsRaw = useSyncExternalStore(
    subscribeCredentials,
    credentialsSnapshot,
    serverCredentialsSnapshot,
  );
  const savedCredentials = useMemo(
    () => parseCredentials(savedCredentialsRaw),
    [savedCredentialsRaw],
  );
  const [credentialDraft, setCredentialDraft] =
    useState<SessionCredentials | null>(null);
  const credentials =
    credentialDraft ?? savedCredentials ?? DEFAULT_SESSION_CREDENTIALS;
  const rememberCredentials = savedCredentials !== null;
  const {
    openAIConnectionMode,
    openAIKey,
    openAIModel,
    ccSwitchCodexModel,
    ccSwitchBaseURL,
    ccSwitchToken,
    deepSeekKey,
    deepSeekModel,
  } = credentials;
  const pendingSuggestion = capture.aiHistory.find((item) => item.suggestion?.status === "pending")?.suggestion;
  const payload = pendingSuggestion?.payload;
  const latestAppliedOutcome = capture.aiHistory.find(
    (item) =>
      item.taskType === "organize" &&
      item.suggestion &&
      ["accepted", "modified", "rolled_back"].includes(
        item.suggestion.status,
      ),
  )?.suggestion;
  const rollbackableSuggestion =
    latestAppliedOutcome?.status === "accepted" ||
    latestAppliedOutcome?.status === "modified"
      ? latestAppliedOutcome.acceptedPayload?.rollback
        ? latestAppliedOutcome
        : null
      : null;
  const [title, setTitle] = useState(payload?.suggested_title ?? "");
  const [contentType, setContentType] = useState<ContentType>(payload?.content_type ?? capture.contentType);
  const [existingCategoryIds, setExistingCategoryIds] = useState(
    payload?.existing_category_candidates.map((item) => item.category_id) ?? [],
  );
  const [newCategoryNames, setNewCategoryNames] = useState(
    [] as string[],
  );
  const [contentSuggestionIndexes, setContentSuggestionIndexes] = useState<number[]>([]);
  const [claimCandidateIndexes, setClaimCandidateIndexes] = useState<number[]>([]);
  const [message, setMessage] = useState("");
  const [processing, setProcessing] = useState(false);
  const [rollingBack, setRollingBack] = useState(false);
  const [confirmingRollback, setConfirmingRollback] = useState(false);
  const [elapsedSeconds, setElapsedSeconds] = useState(0);
  const [auditingClaimId, setAuditingClaimId] = useState<string | null>(null);
  const [auditElapsedSeconds, setAuditElapsedSeconds] = useState(0);
  const [isPending, startTransition] = useTransition();
  const [isConnectionPending, startConnectionTransition] = useTransition();
  const [ccSwitchStatus, setCCSwitchStatus] =
    useState<CCSwitchConnectionStatus>({
      phase: "idle",
      title: "等待检测",
      message: "选择 CC-Switch 后会自动检查本地代理。",
    });
  const categoryNames = useMemo(
    () => new Map(categories.map((category) => [category.id, category.name])),
    [categories],
  );
  const isBusy = processing || auditingClaimId !== null || isPending;
  const proposedContent = useMemo(
    () =>
      payload
        ? applySelectedContentSuggestions(
            capture.content,
            payload.content_suggestions,
            contentSuggestionIndexes,
          )
        : capture.content,
    [capture.content, contentSuggestionIndexes, payload],
  );
  const usesCCSwitchCurrentProvider =
    provider === "openai" &&
    openAIConnectionMode === "ccswitch_auto";
  const ccSwitchReady =
    ccSwitchStatus.phase === "reachable" || ccSwitchStatus.phase === "ready";
  const providerDisplayName =
    provider === "openai"
      ? openAIConnectionMode === "ccswitch_codex_oauth"
        ? "CC-Switch · Codex OAuth"
        : openAIConnectionMode === "ccswitch_auto"
          ? "CC-Switch · 当前供应商"
        : openAIConnectionMode === "ccswitch"
          ? "OpenAI · CC-Switch"
          : "OpenAI · 官方 API"
      : provider === "deepseek"
        ? "DeepSeek"
        : "本地规则";
  const processingPhase =
    elapsedSeconds < 2
      ? "正在创建处理任务…"
      : elapsedSeconds < 8
        ? "AI 正在分析原文与现有分类…"
        : "正在等待模型生成并校验结构化建议…";

  useEffect(() => {
    if (!processing) return;
    const startedAt = Date.now();
    const timer = window.setInterval(() => {
      setElapsedSeconds(Math.floor((Date.now() - startedAt) / 1_000));
    }, 500);
    return () => window.clearInterval(timer);
  }, [processing]);

  useEffect(() => {
    if (!auditingClaimId) return;
    const startedAt = Date.now();
    const timer = window.setInterval(() => {
      setAuditElapsedSeconds(Math.floor((Date.now() - startedAt) / 1_000));
    }, 500);
    return () => window.clearInterval(timer);
  }, [auditingClaimId]);

  useEffect(() => {
    if (!usesCCSwitchCurrentProvider) {
      return;
    }

    let cancelled = false;
    const timer = window.setTimeout(() => {
      setCCSwitchStatus({
        phase: "checking",
        title: "正在自动检测 CC-Switch",
        message: "健康检查不会调用模型，也不会消耗额度。",
      });
      void (async () => {
        const result = await detectCCSwitchAction({
          baseURL: ccSwitchBaseURL.trim() || DEFAULT_CC_SWITCH_BASE_URL,
        });
        if (cancelled) return;
        if (result.ok) {
          const routeUsable =
            result.data.directMessagesCompatible || result.data.routeActive;
          setCCSwitchStatus({
            phase: routeUsable ? "reachable" : "error",
            title: result.data.activeProvider
              ? `已识别当前供应商：${result.data.activeProvider}`
              : "已检测到 CC-Switch",
            message: result.data.activeProvider
              ? result.data.directMessagesCompatible
                ? `已确认 ${result.data.activeProvider} 可通过 CC-Switch Messages 兼容入口工作（${result.data.latencyMs}ms），现在可以直接开始整理。`
                : result.data.routeActive
                  ? `CC-Switch ${result.data.activeAppType ?? "当前"} 路由目标已就绪（${result.data.latencyMs}ms），现在可以直接开始整理。`
                  : `已读取 CC-Switch 当前供应商（${result.data.latencyMs}ms），但尚未发现可安全使用的代理协议。可运行模型测试查看具体错误。`
              : routeUsable
                ? `本地代理和模型路由已就绪（${result.data.latencyMs}ms）；供应商名称未识别，但可以直接开始整理。`
                : `本地代理响应正常（${result.data.latencyMs}ms），但未发现可用模型路由。请运行模型测试查看具体错误。`,
          });
        } else {
          setCCSwitchStatus({
            phase: "error",
            title: "未能连接 CC-Switch",
            message: result.error.message,
          });
        }
      })();
    }, 300);

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [
    ccSwitchBaseURL,
    ccSwitchCodexModel,
    ccSwitchToken,
    usesCCSwitchCurrentProvider,
  ]);

  function updateCredentials(patch: Partial<SessionCredentials>) {
    const next = { ...credentials, ...patch };
    setCredentialDraft(next);
    if (rememberCredentials) {
      window.sessionStorage.setItem(
        AI_CREDENTIAL_SESSION_KEY,
        JSON.stringify(next),
      );
      window.dispatchEvent(new Event(AI_CREDENTIAL_EVENT));
    }
  }

  function changeCredentialMemory(remember: boolean) {
    setCredentialDraft(credentials);
    if (remember) {
      window.sessionStorage.setItem(
        AI_CREDENTIAL_SESSION_KEY,
        JSON.stringify(credentials),
      );
    } else {
      window.sessionStorage.removeItem(AI_CREDENTIAL_SESSION_KEY);
    }
    window.dispatchEvent(new Event(AI_CREDENTIAL_EVENT));
  }

  function connectionForRequest() {
    if (provider === "openai") {
      const model = openAIModel.trim() || undefined;
      if (openAIConnectionMode === "ccswitch_auto") {
        return {
          mode: "ccswitch_auto" as const,
          baseURL: ccSwitchBaseURL.trim() || DEFAULT_CC_SWITCH_BASE_URL,
          apiKey: ccSwitchToken.trim() || undefined,
          model: ccSwitchCodexModel.trim() || "claude-sonnet-4-5",
        };
      }
      if (openAIConnectionMode === "ccswitch_codex_oauth") {
        return {
          mode: "ccswitch_codex_oauth" as const,
          baseURL: ccSwitchBaseURL.trim() || DEFAULT_CC_SWITCH_BASE_URL,
          apiKey: ccSwitchToken.trim() || undefined,
          model: ccSwitchCodexModel.trim() || "claude-sonnet-4-5",
        };
      }
      if (openAIConnectionMode === "ccswitch") {
        return {
          mode: "ccswitch" as const,
          baseURL: ccSwitchBaseURL.trim() || DEFAULT_CC_SWITCH_BASE_URL,
          apiKey: ccSwitchToken.trim() || undefined,
          model,
        };
      }
      if (openAIKey.trim()) {
        return {
          mode: "api_key" as const,
          apiKey: openAIKey.trim(),
          model,
        };
      }
      return { mode: "server" as const, model };
    }

    if (provider === "deepseek") {
      const model = deepSeekModel.trim() || undefined;
      if (deepSeekKey.trim()) {
        return {
          mode: "api_key" as const,
          apiKey: deepSeekKey.trim(),
          model,
        };
      }
      return { mode: "server" as const, model };
    }

    return undefined;
  }

  function testCCSwitchConnection() {
    setCCSwitchStatus({
      phase: "testing",
      title: "正在测试当前供应商",
      message: "正在发送一个极小的结构化请求，通常几秒内完成。",
    });
    startConnectionTransition(async () => {
      const result = await testCCSwitchCurrentProviderAction({
        baseURL: ccSwitchBaseURL.trim() || DEFAULT_CC_SWITCH_BASE_URL,
        apiKey: ccSwitchToken.trim() || undefined,
        model: ccSwitchCodexModel.trim() || "claude-sonnet-4-5",
      });
      if (result.ok) {
        setCCSwitchStatus({
          phase: "ready",
          title: result.data.providerName
            ? `${result.data.providerName} 可用于 AI 整理`
            : "当前供应商可用于 AI 整理",
          message: `${result.data.appType ?? "当前"} · ${result.data.protocol} · ${result.data.routedModel} → ${result.data.actualModel}（${result.data.latencyMs}ms）`,
        });
      } else {
        setCCSwitchStatus({
          phase: "error",
          title: "当前供应商暂不可用于 AI 整理",
          message: result.error.message,
        });
      }
    });
  }

  function runAI() {
    setMessage("");
    if (!editorReady) {
      setMessage("正在确认记录的保存状态，请稍候再试。");
      return;
    }
    if (hasUnsavedChanges) {
      setMessage(
        `检测到原始记录有未保存修改。请先保存，再分析已保存版本 v${capture.version}。`,
      );
      const saveButton = document.querySelector<HTMLButtonElement>(
        "#capture-save-button",
      );
      saveButton?.scrollIntoView({ behavior: "smooth", block: "center" });
      saveButton?.focus({ preventScroll: true });
      return;
    }
    setElapsedSeconds(0);
    setProcessing(true);
    startTransition(async () => {
      try {
        const result = await organizeCaptureAction({
          captureId: capture.id,
          expectedCaptureVersion: capture.version,
          provider,
          connection: connectionForRequest(),
        });
        if (!result.ok) {
          setMessage(result.error.message);
          return;
        }
        router.refresh();
      } finally {
        setProcessing(false);
      }
    });
  }

  function requestRollback() {
    if (!rollbackableSuggestion) return;
    setMessage("");
    if (!editorReady) {
      setMessage("正在确认记录的保存状态，请稍候再试。");
      return;
    }
    if (hasUnsavedChanges) {
      setMessage("请先保存或放弃当前手动修改，再整体回退 AI 整理。");
      document.querySelector<HTMLButtonElement>("#capture-save-button")?.focus();
      return;
    }
    setConfirmingRollback(true);
  }

  function rollbackAI() {
    if (!rollbackableSuggestion || hasUnsavedChanges) return;
    setMessage("");
    setRollingBack(true);
    startTransition(async () => {
      try {
        const result = await rollbackSuggestionAction({
          suggestionId: rollbackableSuggestion.id,
          expectedCaptureVersion: capture.version,
        });
        if (!result.ok) {
          setMessage(result.error.message);
          return;
        }
        setConfirmingRollback(false);
        router.refresh();
      } catch {
        setMessage("整体回退请求未完成，请检查服务状态后重试。原记录没有被覆盖。");
      } finally {
        setRollingBack(false);
      }
    });
  }

  function runClaimAudit(claimId: string) {
    setMessage("");
    setAuditElapsedSeconds(0);
    setAuditingClaimId(claimId);
    startTransition(async () => {
      try {
        const result = await auditClaimAction({
          claimId,
          provider,
          connection: connectionForRequest(),
        });
        if (!result.ok) {
          setMessage(result.error.message);
          return;
        }
        router.refresh();
      } finally {
        setAuditingClaimId(null);
      }
    });
  }

  function decide(decision: "accepted" | "modified" | "rejected") {
    if (!pendingSuggestion) return;
    setMessage("");
    startTransition(async () => {
      const result = await decideSuggestionAction({
        suggestionId: pendingSuggestion.id,
        decision,
        acceptedFields:
          decision === "rejected"
            ? undefined
            : {
                title: title || null,
                contentType,
                existingCategoryIds,
                newCategoryNames,
                contentSuggestionIndexes,
                claimCandidateIndexes,
              },
      });
      if (!result.ok) {
        setMessage(result.error.message);
        return;
      }
      if (result.data.stale) setMessage("原文已发生变化，这条建议已标记为过期。");
      router.refresh();
    });
  }

  function toggleExisting(id: string) {
    setExistingCategoryIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  }

  function toggleNew(name: string) {
    setNewCategoryNames((current) => current.includes(name) ? current.filter((value) => value !== name) : [...current, name]);
  }

  function toggleContentSuggestion(index: number) {
    setContentSuggestionIndexes((current) =>
      current.includes(index)
        ? current.filter((value) => value !== index)
        : [...current, index],
    );
  }

  function toggleClaimCandidate(index: number) {
    setClaimCandidateIndexes((current) =>
      current.includes(index)
        ? current.filter((value) => value !== index)
        : [...current, index],
    );
  }

  function acceptCurrentSelection() {
    if (!payload) return;
    const sameValues = (left: string[], right: string[]) =>
      left.length === right.length && left.every((value) => right.includes(value));
    const originalExisting = payload.existing_category_candidates.map((item) => item.category_id);
    const originalNew = payload.new_category_candidates.map((item) => item.name);
    const changed =
      title.trim() !== payload.suggested_title ||
      contentType !== payload.content_type ||
      !sameValues(existingCategoryIds, originalExisting) ||
      !sameValues(newCategoryNames, originalNew) ||
      contentSuggestionIndexes.length > 0 ||
      claimCandidateIndexes.length > 0;
    decide(changed ? "modified" : "accepted");
  }

  return (
    <section className="ai-panel">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">Assisted processing</p>
          <h2>AI 整理台</h2>
        </div>
        <Bot size={22} />
      </div>

      {!pendingSuggestion ? (
        <div className="ai-empty">
          <div className="ai-orbit"><Sparkles size={22} /></div>
          <h3>生成一份可审阅的整理建议</h3>
          <p>AI 会给出少量分类和局部原文修改建议。任何内容都要经过你勾选、接受后才会写回。</p>
          <div className={`ai-save-preflight${!editorReady ? " is-checking" : hasUnsavedChanges ? " is-unsaved" : " is-saved"}`}>
            {!editorReady ? <LoaderCircle className="processing-spinner" size={17} /> : hasUnsavedChanges ? <CircleAlert size={17} /> : <Save size={17} />}
            <div>
              <strong>{!editorReady ? "正在确认保存状态" : hasUnsavedChanges ? "请先保存当前修改" : `将分析已保存版本 v${capture.version}`}</strong>
              <p>
                {!editorReady
                  ? "确认完成前不会启动 AI，避免遗漏正在编辑的内容。"
                  : hasUnsavedChanges
                  ? "AI 不会分析左侧尚未保存的内容；点击整理会定位到“保存修改”。"
                  : "AI 只读取数据库中的已保存内容，不会读取正在编辑但尚未保存的文字。"}
              </p>
            </div>
          </div>
          <label className="provider-select">
            <span>处理引擎</span>
            <select disabled={!editorReady || isBusy} value={provider} onChange={(event) => setProvider(event.target.value as typeof provider)}>
              <option value="mock">本地规则（无需密钥）</option>
              <option value="openai">CC-Switch / OpenAI</option>
              <option value="deepseek">DeepSeek</option>
            </select>
          </label>
          {provider === "openai" ? (
            <div className="ai-connection-card">
              <label className="credential-field">
                <span>连接方式</span>
                <select
                  aria-label="OpenAI 连接方式"
                  value={openAIConnectionMode}
                  onChange={(event) =>
                    updateCredentials({
                      openAIConnectionMode:
                        event.target.value as OpenAIConnectionMode,
                    })
                  }
                >
                  <option value="ccswitch_auto">CC-Switch（跟随当前供应商，推荐）</option>
                  <option value="api_key">官方 API Key</option>
                </select>
              </label>
              {openAIConnectionMode === "api_key" ? (
                <>
                  <label className="credential-field">
                    <span>OpenAI API Key</span>
                    <input
                      aria-label="OpenAI API Key"
                      autoComplete="off"
                      onChange={(event) =>
                        updateCredentials({ openAIKey: event.target.value })
                      }
                      placeholder="sk-…（留空使用服务端配置）"
                      type="password"
                      value={openAIKey}
                    />
                  </label>
                  <label className="credential-field">
                    <span>模型 ID（可选）</span>
                    <input
                      aria-label="OpenAI 模型 ID"
                      onChange={(event) =>
                        updateCredentials({ openAIModel: event.target.value })
                      }
                      placeholder="留空使用服务端默认模型"
                      value={openAIModel}
                    />
                  </label>
                </>
              ) : openAIConnectionMode === "ccswitch_auto" ? (
                <>
                  <div
                    aria-live="polite"
                    className={`connection-check is-${ccSwitchStatus.phase}`}
                    role="status"
                  >
                    {ccSwitchStatus.phase === "checking" ||
                    ccSwitchStatus.phase === "testing" ? (
                      <LoaderCircle className="processing-spinner" size={19} />
                    ) : ccSwitchStatus.phase === "reachable" ||
                      ccSwitchStatus.phase === "ready" ? (
                      <CircleCheck size={19} />
                    ) : (
                      <CircleAlert size={19} />
                    )}
                    <div>
                      <strong>{ccSwitchStatus.title}</strong>
                      <p>{ccSwitchStatus.message}</p>
                    </div>
                  </div>
                  <button
                    className="button button-quiet connection-test-button"
                    disabled={isConnectionPending || ccSwitchStatus.phase === "checking"}
                    onClick={testCCSwitchConnection}
                    type="button"
                  >
                    {ccSwitchStatus.phase === "testing" ? (
                      <LoaderCircle className="processing-spinner" size={15} />
                    ) : (
                      <PlugZap size={15} />
                    )}
                    {ccSwitchStatus.phase === "testing"
                      ? "正在测试"
                      : "模型测试（可选）"}
                  </button>
                  <p className="connection-test-note">
                    自动检测到可用路由后即可直接整理；仅在排查模型或供应商切换问题时需要运行模型测试。
                  </p>
                  <details className="connection-advanced">
                    <summary>高级设置（通常无需修改）</summary>
                    <div>
                      <label className="credential-field">
                        <span>CC-Switch 地址</span>
                        <input
                          aria-label="CC-Switch 地址"
                          onChange={(event) =>
                            updateCredentials({ ccSwitchBaseURL: event.target.value })
                          }
                          placeholder={DEFAULT_CC_SWITCH_BASE_URL}
                          type="url"
                          value={ccSwitchBaseURL}
                        />
                      </label>
                      <label className="credential-field">
                        <span>模型路由名</span>
                        <input
                          aria-label="CC-Switch 模型路由名"
                          onChange={(event) =>
                            updateCredentials({ ccSwitchCodexModel: event.target.value })
                          }
                          placeholder="claude-sonnet-4-5"
                          value={ccSwitchCodexModel}
                        />
                      </label>
                      <label className="credential-field">
                        <span>代理令牌（一般留空）</span>
                        <input
                          aria-label="CC-Switch 代理令牌"
                          autoComplete="off"
                          onChange={(event) =>
                            updateCredentials({ ccSwitchToken: event.target.value })
                          }
                          placeholder="不要填写供应商的 OAuth token"
                          type="password"
                          value={ccSwitchToken}
                        />
                      </label>
                    </div>
                  </details>
                </>
              ) : (
                <>
                  <p className="credential-note">
                    此高级模式使用 /v1/responses；你当前的 CC-Switch 配置不适用。
                  </p>
                  <label className="credential-field">
                    <span>CC-Switch 地址</span>
                    <input
                      aria-label="CC-Switch 地址"
                      onChange={(event) =>
                        updateCredentials({ ccSwitchBaseURL: event.target.value })
                      }
                      placeholder={DEFAULT_CC_SWITCH_BASE_URL}
                      type="url"
                      value={ccSwitchBaseURL}
                    />
                  </label>
                  <label className="credential-field">
                    <span>模型 ID（可选）</span>
                    <input
                      aria-label="OpenAI 模型 ID"
                      onChange={(event) =>
                        updateCredentials({ openAIModel: event.target.value })
                      }
                      placeholder="留空使用服务端默认模型"
                      value={openAIModel}
                    />
                  </label>
                </>
              )}
            </div>
          ) : null}
          {provider === "deepseek" ? (
            <div className="ai-connection-card">
              <label className="credential-field">
                <span>DeepSeek API Key</span>
                <input
                  aria-label="DeepSeek API Key"
                  autoComplete="off"
                  onChange={(event) =>
                    updateCredentials({ deepSeekKey: event.target.value })
                  }
                  placeholder="sk-…（留空使用服务端配置）"
                  type="password"
                  value={deepSeekKey}
                />
              </label>
              <label className="credential-field">
                <span>模型 ID（可选）</span>
                <input
                  aria-label="DeepSeek 模型 ID"
                  onChange={(event) =>
                    updateCredentials({ deepSeekModel: event.target.value })
                  }
                  placeholder="留空使用服务端默认模型"
                  value={deepSeekModel}
                />
              </label>
            </div>
          ) : null}
          {provider !== "mock" ? (
            <label className="credential-memory">
              <input
                checked={rememberCredentials}
                onChange={(event) =>
                  changeCredentialMemory(event.target.checked)
                }
                type="checkbox"
              />
              <span>仅在当前浏览器标签页记住凭据</span>
            </label>
          ) : null}
          {processing ? (
            <div aria-live="polite" className="ai-processing-status" role="status">
              <LoaderCircle className="processing-spinner" size={20} />
              <div>
                <strong>{providerDisplayName} 正在整理</strong>
                <p>{processingPhase}</p>
              </div>
              <time>{elapsedSeconds}s</time>
              <span className="processing-track"><i /></span>
            </div>
          ) : null}
          <button
            className="button button-dark"
            disabled={!editorReady || isBusy || (usesCCSwitchCurrentProvider && !ccSwitchReady)}
            onClick={runAI}
            type="button"
          >
            <Sparkles size={16} /> {processing ? "处理中，请稍候" : !editorReady ? "正在确认保存状态…" : hasUnsavedChanges ? "先保存，再开始 AI 整理" : usesCCSwitchCurrentProvider && !ccSwitchReady ? "正在确认 CC-Switch 可用性" : `开始分析版本 v${capture.version}`}
          </button>
          {rollbackableSuggestion ? (
            <div className="ai-rollback-card">
              <div>
                <strong>最近一次 AI 整理已写入记录</strong>
                <p>如果整体结果不合适，可以恢复采纳前内容；手动分类和完整版本历史会保留。</p>
              </div>
              <button className="button button-quiet" disabled={!editorReady || isBusy} onClick={requestRollback} type="button">
                <RotateCcw size={15} /> 整体回退这次整理
              </button>
              {confirmingRollback ? (
                <div className="ai-rollback-confirmation" role="alert">
                  <strong>确认整体回退</strong>
                  <ul>
                    <li>恢复采纳前的标题、内容类型、原文和 AI 分类。</li>
                    <li>移除本次创建且尚未开始调查的候选主张。</li>
                    <li>保留手动分类和全部版本历史；回退会生成新的可追溯版本。</li>
                    <li>若记录或候选主张已进入后续处理，系统会拒绝回退，不覆盖新内容。</li>
                  </ul>
                  <div>
                    <button className="button button-quiet" disabled={rollingBack} onClick={() => setConfirmingRollback(false)} type="button">取消</button>
                    <button aria-busy={rollingBack} className="button button-danger" disabled={rollingBack} onClick={rollbackAI} type="button">
                      {rollingBack ? <LoaderCircle className="processing-spinner" size={15} /> : <RotateCcw size={15} />}
                      {rollingBack ? "正在整体回退…" : "确认整体回退"}
                    </button>
                  </div>
                </div>
              ) : null}
            </div>
          ) : null}
        </div>
      ) : (
        <div className="suggestion-review">
          <div className="review-notice">
            <ShieldCheck size={18} />
            <p><strong>等待你的决定</strong><br />下列内容只是建议；接受后才会写入记录。</p>
          </div>
          <label className="field">
            <span>建议标题</span>
            <input maxLength={200} value={title} onChange={(event) => setTitle(event.target.value)} />
          </label>
          <label className="field compact-field">
            <span>建议类型</span>
            <select value={contentType} onChange={(event) => setContentType(event.target.value as ContentType)}>
              {CONTENT_TYPES.map((type) => <option key={type} value={type}>{CONTENT_TYPE_LABELS[type]}</option>)}
            </select>
          </label>
          <div className="suggestion-block">
            <h3>摘要</h3>
            <p>{payload!.summary}</p>
          </div>

          {(payload!.existing_category_candidates.length > 0 || payload!.new_category_candidates.length > 0) ? (
            <div className="suggestion-block">
              <h3>分类建议 · 最多 3 个</h3>
              <p className="suggestion-help">已有分类默认选中；新分类最多 1 个且默认不选。再次接受会替换旧 AI 标签，手动标签不受影响。</p>
              <div className="review-options">
                {payload!.existing_category_candidates.map((candidate) => (
                  <label key={candidate.category_id}>
                    <input checked={existingCategoryIds.includes(candidate.category_id)} onChange={() => toggleExisting(candidate.category_id)} type="checkbox" />
                    <span>{categoryNames.get(candidate.category_id) ?? "已有分类"}<small>{Math.round(candidate.confidence * 100)}% · {candidate.reason}</small></span>
                  </label>
                ))}
                {payload!.new_category_candidates.map((candidate) => (
                  <label key={candidate.name}>
                    <input checked={newCategoryNames.includes(candidate.name)} onChange={() => toggleNew(candidate.name)} type="checkbox" />
                    <span>{candidate.name} <em>新建 · 默认不选</em><small>{Math.round(candidate.confidence * 100)}% · {candidate.reason}</small></span>
                  </label>
                ))}
              </div>
            </div>
          ) : null}

          <div className="suggestion-block content-comparison-block">
            <div className="content-comparison-heading">
              <div>
                <h3>AI 文本替换前后对比</h3>
                <p>随下方局部建议的勾选实时更新；这里只预览，点击“接受当前选择”后才会写回。</p>
              </div>
              <span>{contentSuggestionIndexes.length} 处替换</span>
            </div>
            <div className="content-comparison-grid">
              <article>
                <header><span>修改前</span><small>已保存版本 v{pendingSuggestion.sourceCaptureVersion}</small></header>
                <pre>{capture.content}</pre>
              </article>
              <article className={proposedContent === capture.content ? "is-unchanged" : "is-changed"}>
                <header><span>修改后</span><small>{proposedContent === capture.content ? "尚未选择文本替换" : "应用当前所选建议"}</small></header>
                <pre>{proposedContent}</pre>
              </article>
            </div>
          </div>

          {payload!.content_suggestions.length ? (
            <div className="suggestion-block content-suggestion-block">
              <h3>局部原文建议 · 默认不修改</h3>
              <p className="suggestion-help">逐条勾选需要应用的改动；未选择的原文保持不变，不会整篇覆盖。</p>
              <div className="content-suggestion-list">
                {payload!.content_suggestions.map((suggestion, index) => (
                  <label key={`${suggestion.source_excerpt}-${index}`}>
                    <input
                      checked={contentSuggestionIndexes.includes(index)}
                      onChange={() => toggleContentSuggestion(index)}
                      type="checkbox"
                    />
                    <span className="content-suggestion-icon"><FilePenLine size={15} /></span>
                    <span>
                      <strong>{suggestion.reason}</strong>
                      <small>原文：{suggestion.source_excerpt}</small>
                      <b>建议：{suggestion.suggested_text || "删除这段文字"}</b>
                    </span>
                  </label>
                ))}
              </div>
            </div>
          ) : null}

          {payload!.claim_candidates.length ? (
            <div className="suggestion-block claim-candidate-block">
              <h3>可证伪主张候选 · 默认不创建</h3>
              <p className="suggestion-help">
                勾选后只会创建“候选主张”，不会标记为真实；后续仍需收集和审核证据。
              </p>
              <div className="claim-candidate-list">
                {payload!.claim_candidates.map((candidate, index) => (
                  <label key={`${candidate.statement}-${index}`}>
                    <input
                      checked={claimCandidateIndexes.includes(index)}
                      onChange={() => toggleClaimCandidate(index)}
                      type="checkbox"
                    />
                    <span>
                      <strong>{candidate.statement}</strong>
                      <small>原文：“{candidate.source_excerpt}”</small>
                      <b>证伪条件：{candidate.falsification_criteria}</b>
                      <em>{Math.round(candidate.confidence * 100)}% · {candidate.reason}</em>
                    </span>
                  </label>
                ))}
              </div>
            </div>
          ) : null}

          <div className="suggestion-block">
            <h3>原文语义片段</h3>
            <div className="semantic-list">
              {payload!.semantic_units.map((unit, index) => (
                <div key={`${unit.source_excerpt}-${index}`}>
                  <span>{unit.type}</span>
                  <p>{unit.content}</p>
                  <blockquote>“{unit.source_excerpt}”</blockquote>
                </div>
              ))}
            </div>
          </div>

          {payload!.open_questions.length ? (
            <div className="suggestion-block">
              <h3>可继续追问</h3>
              <ul>{payload!.open_questions.map((question) => <li key={question}>{question}</li>)}</ul>
            </div>
          ) : null}
          {payload!.quality_flags.map((flag) => (
            <p className="quality-flag" key={flag.code}>{flag.message}</p>
          ))}

          <div className="review-actions">
            <button className="button button-quiet" disabled={isBusy} onClick={() => decide("rejected")} type="button"><X size={16} /> 驳回</button>
            <button className="button button-primary" disabled={isBusy} onClick={acceptCurrentSelection} type="button"><Check size={16} /> 接受当前选择</button>
          </div>
        </div>
      )}

      {message ? <p className="form-error action-message">{message}</p> : null}

      {!pendingSuggestion && capture.claims.some((claim) => claim.status !== "withdrawn") ? (
        <div className="claim-ai-audit-section">
          <div className="claim-ai-audit-heading">
            <div>
              <p className="eyebrow">Evidence audit</p>
              <h3>AI 可靠性审查</h3>
            </div>
            <ShieldCheck size={20} />
          </div>
          <p className="claim-ai-audit-boundary">
            AI 只审查已采纳且来源摘录匹配的证据，提示覆盖、平衡与缺口；不会联网补证、修改证据或形成最终结论。
          </p>
          <div className="claim-ai-audit-list">
            {capture.claims
              .filter((claim) => claim.status !== "withdrawn")
              .map((claim) => {
                const latestAudit = claim.aiAudits[0];
                const isAuditing = auditingClaimId === claim.id;
                return (
                  <article className="claim-ai-audit-card" key={claim.id}>
                    <header>
                      <strong>{claim.statement}</strong>
                      <button
                        className="button button-quiet"
                        disabled={
                          isBusy ||
                          (usesCCSwitchCurrentProvider && !ccSwitchReady)
                        }
                        onClick={() => runClaimAudit(claim.id)}
                        type="button"
                      >
                        {isAuditing ? (
                          <LoaderCircle className="processing-spinner" size={14} />
                        ) : (
                          <ShieldCheck size={14} />
                        )}
                        {isAuditing
                          ? `审查中 ${auditElapsedSeconds}s`
                          : latestAudit
                            ? "重新运行可靠性审查"
                            : "运行可靠性审查"}
                      </button>
                    </header>
                    {isAuditing ? (
                      <div
                        aria-live="polite"
                        className="claim-ai-audit-running"
                        role="status"
                      >
                        <LoaderCircle className="processing-spinner" size={17} />
                        正在分析证据快照、正反平衡与待补检查…
                      </div>
                    ) : latestAudit ? (
                      <div className={`claim-ai-audit-result${latestAudit.isStale ? " is-stale" : ""}`}>
                        <div className="claim-ai-audit-meta">
                          <span>{auditCoverageLabels[latestAudit.payload.evidence_coverage]}</span>
                          <span>{auditBalanceLabels[latestAudit.payload.evidence_balance]}</span>
                          <span>{latestAudit.evidenceCount} 条证据快照</span>
                          {latestAudit.isStale ? <b>输入已变化，请重新审查</b> : null}
                        </div>
                        <p>{latestAudit.payload.summary}</p>
                        <div className="claim-ai-audit-recommendation">
                          AI 建议：{auditAssessmentLabels[latestAudit.payload.recommended_assessment]}（仅供人工参考）
                        </div>
                        {latestAudit.payload.findings.length ? (
                          <ul className="claim-ai-audit-findings">
                            {latestAudit.payload.findings.map((finding, index) => (
                              <li className={`is-${finding.severity}`} key={`${finding.category}-${index}`}>
                                <b>{auditFindingLabels[finding.category]}</b>
                                <span>{finding.message}</span>
                              </li>
                            ))}
                          </ul>
                        ) : null}
                        {latestAudit.payload.missing_checks.length ? (
                          <div className="claim-ai-audit-missing">
                            <strong>建议补充检查</strong>
                            <ol>
                              {latestAudit.payload.missing_checks.map((item) => (
                                <li key={item}>{item}</li>
                              ))}
                            </ol>
                          </div>
                        ) : null}
                        <small>
                          {latestAudit.payload.boundary_notice} · {historyProviderLabel(latestAudit.provider)} / {latestAudit.model}
                          {latestAudit.latencyMs
                            ? ` · ${(latestAudit.latencyMs / 1_000).toFixed(1)}s`
                            : ""}
                        </small>
                      </div>
                    ) : (
                      <p className="claim-ai-audit-empty">
                        尚未审查。即使没有证据也可以运行，系统会明确记录覆盖缺口。
                      </p>
                    )}
                  </article>
                );
              })}
          </div>
        </div>
      ) : null}

      {capture.aiHistory.length ? (
        <details className="history-list">
          <summary>处理历史 · {capture.aiHistory.length}</summary>
          {capture.aiHistory.map((item) => (
            <div key={item.id}>
              <span>
                {item.taskType === "claim_audit" ? "可靠性审查" : "内容整理"} · {historyProviderLabel(item.provider)} / {item.model}
              </span>
              <small>
                {item.suggestion ? statusLabels[item.suggestion.status] : runStatusLabels[item.status]}
                {item.latencyMs ? ` · ${(item.latencyMs / 1_000).toFixed(1)}s` : ""}
              </small>
            </div>
          ))}
        </details>
      ) : null}
    </section>
  );
}
