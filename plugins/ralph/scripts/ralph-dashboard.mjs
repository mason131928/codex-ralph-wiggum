#!/usr/bin/env node

import http from "node:http";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const loopScriptPath = path.join(__dirname, "ralph-loop.sh");

const args = parseArgs(process.argv.slice(2));
const defaultWorkspace = path.resolve(args.workspace ?? process.cwd());
const host = args.host ?? "127.0.0.1";
const port = Number(args.port ?? 43110);
const infoFile = path.resolve(args.infoFile ?? path.join(defaultWorkspace, ".ralph", "dashboard", "server-info.json"));
const pidFile = path.resolve(args.pidFile ?? path.join(defaultWorkspace, ".ralph", "dashboard", "server.pid"));

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? `${host}:${port}`}`);
    const requestedWorkspace = resolveRequestedWorkspace(url.searchParams.get("workspace"));

    if (request.method === "GET" && url.pathname === "/api/state") {
      sendJson(response, 200, await buildDashboardOverview(requestedWorkspace));
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/workspaces") {
      sendJson(response, 200, {
        generatedAt: new Date().toISOString(),
        currentWorkspace: requestedWorkspace,
        items: await discoverWorkspaces(requestedWorkspace)
      });
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/loop") {
      const loopId = url.searchParams.get("id")?.trim();
      if (!loopId) {
        sendJson(response, 400, { error: "missing_loop_id" });
        return;
      }
      const detail = await readLoopDetail(requestedWorkspace, loopId);
      if (!detail) {
        sendJson(response, 404, { error: "loop_not_found", loopId });
        return;
      }
      sendJson(response, 200, detail);
      return;
    }

    if (request.method === "GET" && url.pathname === "/api/campaign") {
      const campaignId = url.searchParams.get("id")?.trim();
      if (!campaignId) {
        sendJson(response, 400, { error: "missing_campaign_id" });
        return;
      }
      const detail = await readCampaignDetail(requestedWorkspace, campaignId);
      if (!detail) {
        sendJson(response, 404, { error: "campaign_not_found", campaignId });
        return;
      }
      sendJson(response, 200, detail);
      return;
    }

    if (request.method === "GET" && url.pathname === "/events") {
      const stop = startEventStream(response, requestedWorkspace);
      request.on("close", stop);
      return;
    }

    if (request.method === "GET" && url.pathname === "/healthz") {
      sendJson(response, 200, { ok: true, workspace: requestedWorkspace, now: new Date().toISOString() });
      return;
    }

    if (request.method === "GET" && url.pathname === "/") {
      sendHtml(response, renderDashboardHtml());
      return;
    }

    sendJson(response, 404, { error: "not_found" });
  } catch (error) {
    sendJson(response, 500, {
      error: "internal_error",
      message: error instanceof Error ? error.message : String(error)
    });
  }
});

server.listen(port, host, async () => {
  const address = server.address();
  const resolvedPort = typeof address === "object" && address ? address.port : port;
  const url = `http://${host}:${resolvedPort}`;

  await fs.mkdir(path.dirname(infoFile), { recursive: true });
  await fs.writeFile(
    infoFile,
    JSON.stringify(
      {
        url,
        host,
        port: resolvedPort,
        workspace: defaultWorkspace,
        pid: process.pid,
        startedAt: new Date().toISOString(),
        script: loopScriptPath
      },
      null,
      2
    )
  );
  await fs.writeFile(pidFile, `${process.pid}\n`);
  console.log(`Ralph dashboard listening on ${url}`);
});

async function shutdown(signal) {
  try {
    await fs.rm(pidFile, { force: true });
  } catch {}

  server.close(() => {
    if (signal) {
      process.exit(0);
    }
  });
}

process.on("SIGINT", () => {
  void shutdown("SIGINT");
});

process.on("SIGTERM", () => {
  void shutdown("SIGTERM");
});

function resolveRequestedWorkspace(value) {
  if (!value) return defaultWorkspace;
  try {
    return path.resolve(value);
  } catch {
    return defaultWorkspace;
  }
}

function startEventStream(response, workspace) {
  let closed = false;
  response.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-store",
    connection: "keep-alive"
  });

  const send = async () => {
    if (closed) return;
    const payload = await buildDashboardOverview(workspace);
    response.write(`event: snapshot\n`);
    response.write(`data: ${JSON.stringify(payload)}\n\n`);
  };

  void send().catch(() => {});
  const interval = setInterval(() => {
    void send().catch(() => {});
  }, 3000);

  return () => {
    if (closed) return;
    closed = true;
    clearInterval(interval);
    response.end();
  };
}

async function buildDashboardOverview(currentWorkspace) {
  const ralphRoot = path.join(currentWorkspace, ".ralph");
  const loopsRoot = path.join(ralphRoot, "loops");
  const campaignsRoot = path.join(ralphRoot, "campaigns");
  const activeLoopId = await readTrimmed(path.join(ralphRoot, "active-loop"));
  const activeCampaignId = await readTrimmed(path.join(ralphRoot, "active-campaign"));

  const [loopIds, campaignIds, workspaceBoundaries] = await Promise.all([
    listDirectoriesNewestFirst(loopsRoot),
    listDirectoriesNewestFirst(campaignsRoot),
    readWorkspaceBoundarySnapshot(currentWorkspace)
  ]);

  const [loops, campaigns] = await Promise.all([
    Promise.all(loopIds.slice(0, 28).map((loopId) => readLoopOverview(currentWorkspace, loopId))),
    Promise.all(campaignIds.slice(0, 14).map((campaignId) => readCampaignOverview(currentWorkspace, campaignId)))
  ]);

  const filteredLoops = loops.filter(Boolean);
  const filteredCampaigns = campaigns.filter(Boolean);
  const summary = buildOverviewSummary({
    loops: filteredLoops,
    campaigns: filteredCampaigns,
    activeLoopId,
    activeCampaignId,
    workspaceBoundaries
  });

  return {
    generatedAt: new Date().toISOString(),
    workspace: currentWorkspace,
    activeLoopId,
    activeCampaignId,
    workspaceBoundaries,
    summary,
    loops: filteredLoops,
    campaigns: filteredCampaigns,
    activityFeed: buildActivityFeed({
      loops: filteredLoops,
      campaigns: filteredCampaigns,
      activeLoopId,
      activeCampaignId
    })
  };
}

async function discoverWorkspaces(currentWorkspace) {
  const candidates = new Map();
  const currentParent = path.dirname(currentWorkspace);
  candidates.set(currentWorkspace, true);

  for (const root of [currentParent, defaultWorkspace, path.dirname(defaultWorkspace)]) {
    try {
      const entries = await fs.readdir(root, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const fullPath = path.join(root, entry.name);
        candidates.set(fullPath, true);
      }
    } catch {}
  }

  const items = [];
  for (const candidate of candidates.keys()) {
    const card = await readWorkspaceCard(candidate, { includeWithoutRalph: candidate === currentWorkspace });
    if (card) items.push(card);
  }

  items.sort((left, right) => timestampValue(right.updatedAt) - timestampValue(left.updatedAt) || left.name.localeCompare(right.name));
  return items.slice(0, 40);
}

async function readWorkspaceCard(candidate, options = {}) {
  const ralphRoot = path.join(candidate, ".ralph");
  const loopsRoot = path.join(ralphRoot, "loops");
  const campaignsRoot = path.join(ralphRoot, "campaigns");
  const hasRalph = await fileExists(ralphRoot);
  if (!hasRalph && !options.includeWithoutRalph) return null;

  const [activeLoopId, activeCampaignId, loopIds, campaignIds, boundaries] = await Promise.all([
    readTrimmed(path.join(ralphRoot, "active-loop")),
    readTrimmed(path.join(ralphRoot, "active-campaign")),
    listDirectoriesNewestFirst(loopsRoot),
    listDirectoriesNewestFirst(campaignsRoot),
    readWorkspaceBoundarySnapshot(candidate)
  ]);

  const activeLoop = activeLoopId ? await readLoopOverview(candidate, activeLoopId) : null;
  const activeCampaign = activeCampaignId ? await readCampaignOverview(candidate, activeCampaignId) : null;
  const latestLoop =
    activeLoop ||
    (loopIds[0]
      ? await readLoopOverview(candidate, loopIds[0])
      : null);

  return {
    path: candidate,
    name: path.basename(candidate),
    hasRalph,
    activeLoopId,
    activeCampaignId,
    loopCount: loopIds.length,
    campaignCount: campaignIds.length,
    status: activeLoop?.status || activeCampaign?.status || latestLoop?.status || "idle",
    iteration: activeLoop?.iteration || latestLoop?.iteration || 0,
    updatedAt: activeLoop?.updatedAt || activeCampaign?.updatedAt || latestLoop?.updatedAt || "",
    missionHeadline: activeLoop?.taskHeadline || activeCampaign?.goalHeadline || latestLoop?.taskHeadline || "No active Ralph mission detected.",
    boundaryCount: boundaries?.count ?? null,
    activeLoopTaskPreview: activeLoop?.taskPreview || latestLoop?.taskPreview || ""
  };
}

async function readLoopOverview(currentWorkspace, loopId) {
  const loopDir = path.join(currentWorkspace, ".ralph", "loops", loopId);
  const state = await readLoopState(loopDir);
  if (!state) return null;

  const [task, handoff, iterations] = await Promise.all([
    readTrimmed(path.join(loopDir, "task.md")),
    readTail(path.join(loopDir, "handoff.md"), 42),
    readIterationSummaries(path.join(loopDir, "iterations"), 3, {
      currentWorkspace,
      detailed: false
    })
  ]);

  const latestIteration = iterations[0] ?? null;
  const latestCompleted = latestIteration?.isInFlight ? iterations[1] ?? null : latestIteration;

  return {
    kind: "loop",
    id: state.LOOP_ID || loopId,
    status: state.STATUS || "unknown",
    workspace: state.WORKSPACE || currentWorkspace,
    createdAt: state.CREATED_AT || "",
    updatedAt: state.UPDATED_AT || "",
    iteration: Number(state.ITERATION || 0),
    maxIterations: state.MAX_ITERATIONS || "0",
    model: state.MODEL || "default",
    profile: state.PROFILE || "default",
    sandboxMode: state.SANDBOX_MODE || "",
    approvalPolicy: state.APPROVAL_POLICY || "",
    pid: state.PID || "",
    lastExitCode: state.LAST_EXIT_CODE || "",
    consecutiveErrors: Number(state.CONSECUTIVE_ERRORS || 0),
    consecutiveErrorLimit: Number(state.CONSECUTIVE_ERROR_LIMIT || 0),
    taskHeadline: extractHeadline(task, `Loop ${loopId}`),
    taskPreview: truncate(task, 420),
    handoffPreview: truncate(handoff, 420),
    latestIteration: latestIteration
      ? {
          id: latestIteration.id,
          startedAt: latestIteration.startedAt,
          endedAt: latestIteration.endedAt,
          exitCode: latestIteration.exitCode,
          isInFlight: latestIteration.isInFlight,
          finalMessagePreview: truncate(latestIteration.finalMessage || "", 320),
          stderrPreview: truncate(latestIteration.stderrTail || "", 220)
        }
      : null,
    latestCompletedMessage: truncate(latestCompleted?.finalMessage || "", 380)
  };
}

async function readLoopDetail(currentWorkspace, loopId) {
  const loopDir = path.join(currentWorkspace, ".ralph", "loops", loopId);
  const state = await readLoopState(loopDir);
  if (!state) return null;

  const [task, handoff, lastMessage, iterations] = await Promise.all([
    readTrimmed(path.join(loopDir, "task.md")),
    readTrimmed(path.join(loopDir, "handoff.md")),
    readTail(state.LAST_OUTPUT_FILE || path.join(loopDir, "last-output.txt"), 140),
    readIterationSummaries(path.join(loopDir, "iterations"), 100, {
      currentWorkspace,
      detailed: true
    })
  ]);

  const currentIteration = iterations.find((iteration) => iteration.isInFlight) ?? iterations[0] ?? null;
  const files = aggregateFileRefs(
    currentWorkspace,
    [
      { source: "task", text: task },
      { source: "handoff", text: handoff },
      { source: "last_message", text: lastMessage },
      ...iterations.flatMap((iteration) => [
        { source: `${iteration.id}:closeout`, text: iteration.finalMessage },
        { source: `${iteration.id}:stderr`, text: iteration.stderrTail },
        { source: `${iteration.id}:session`, text: iteration.sessionTail },
        { source: `${iteration.id}:prompt`, text: iteration.promptPreview },
        { source: `${iteration.id}:task`, text: iteration.taskPreview }
      ])
    ],
    80
  );

  return {
    kind: "loop",
    id: state.LOOP_ID || loopId,
    status: state.STATUS || "unknown",
    workspace: state.WORKSPACE || currentWorkspace,
    createdAt: state.CREATED_AT || "",
    updatedAt: state.UPDATED_AT || "",
    iteration: Number(state.ITERATION || 0),
    maxIterations: state.MAX_ITERATIONS || "0",
    model: state.MODEL || "default",
    profile: state.PROFILE || "default",
    sandboxMode: state.SANDBOX_MODE || "",
    approvalPolicy: state.APPROVAL_POLICY || "",
    pid: state.PID || "",
    lastExitCode: state.LAST_EXIT_CODE || "",
    consecutiveErrors: Number(state.CONSECUTIVE_ERRORS || 0),
    consecutiveErrorLimit: Number(state.CONSECUTIVE_ERROR_LIMIT || 0),
    taskHeadline: extractHeadline(task, `Loop ${loopId}`),
    task,
    handoff,
    lastMessage,
    currentIterationId: currentIteration?.id || "",
    iterations,
    files
  };
}

async function readCampaignOverview(currentWorkspace, campaignId) {
  const campaignDir = path.join(currentWorkspace, ".ralph", "campaigns", campaignId);
  const state = await readCampaignState(campaignDir);
  if (!state) return null;

  const [goal, boundarySnapshot, verifyLog] = await Promise.all([
    readTrimmed(state.GOAL_FILE || path.join(campaignDir, "goal.md")),
    readTail(state.BOUNDARY_SNAPSHOT_FILE || path.join(campaignDir, "current-boundaries.md"), 50),
    readTail(state.LAST_VERIFY_LOG || "", 42)
  ]);

  return {
    kind: "campaign",
    id: state.CAMPAIGN_ID || campaignId,
    status: state.STATUS || "unknown",
    workspace: state.WORKSPACE || currentWorkspace,
    createdAt: state.CREATED_AT || "",
    updatedAt: state.UPDATED_AT || "",
    round: Number(state.ROUND || 0),
    maxRounds: state.MAX_ROUNDS || "0",
    currentLoopId: state.CURRENT_LOOP_ID || "",
    loopMaxIterations: state.LOOP_MAX_ITERATIONS || "0",
    model: state.MODEL || "default",
    profile: state.PROFILE || "default",
    sandboxMode: state.SANDBOX_MODE || "",
    approvalPolicy: state.APPROVAL_POLICY || "",
    pid: state.PID || "",
    verifyCommand: state.VERIFY_CMD || "",
    lastVerifyExitCode: state.LAST_VERIFY_EXIT_CODE || "",
    remainingBoundaries: Number(state.LAST_BOUNDARY_COUNT || 0),
    goalHeadline: extractHeadline(goal, `Campaign ${campaignId}`),
    goalPreview: truncate(goal, 420),
    boundarySnapshotPreview: truncate(boundarySnapshot, 420),
    lastVerifyLogPreview: truncate(verifyLog, 420)
  };
}

async function readCampaignDetail(currentWorkspace, campaignId) {
  const campaignDir = path.join(currentWorkspace, ".ralph", "campaigns", campaignId);
  const state = await readCampaignState(campaignDir);
  if (!state) return null;

  const [goal, boundarySnapshot, verifyLog] = await Promise.all([
    readTrimmed(state.GOAL_FILE || path.join(campaignDir, "goal.md")),
    readTrimmed(state.BOUNDARY_SNAPSHOT_FILE || path.join(campaignDir, "current-boundaries.md")),
    readTail(state.LAST_VERIFY_LOG || "", 160)
  ]);

  return {
    kind: "campaign",
    id: state.CAMPAIGN_ID || campaignId,
    status: state.STATUS || "unknown",
    workspace: state.WORKSPACE || currentWorkspace,
    createdAt: state.CREATED_AT || "",
    updatedAt: state.UPDATED_AT || "",
    round: Number(state.ROUND || 0),
    maxRounds: state.MAX_ROUNDS || "0",
    currentLoopId: state.CURRENT_LOOP_ID || "",
    loopMaxIterations: state.LOOP_MAX_ITERATIONS || "0",
    model: state.MODEL || "default",
    profile: state.PROFILE || "default",
    sandboxMode: state.SANDBOX_MODE || "",
    approvalPolicy: state.APPROVAL_POLICY || "",
    pid: state.PID || "",
    verifyCommand: state.VERIFY_CMD || "",
    lastVerifyExitCode: state.LAST_VERIFY_EXIT_CODE || "",
    remainingBoundaries: Number(state.LAST_BOUNDARY_COUNT || 0),
    boundaryDoc: state.BOUNDARY_DOC || "",
    boundarySection: state.BOUNDARY_SECTION || "",
    goal,
    boundarySnapshot,
    lastVerifyLog: verifyLog
  };
}

async function readLoopState(loopDir) {
  return sourceStateFile(path.join(loopDir, "state.env"), [
    "LOOP_ID",
    "STATUS",
    "WORKSPACE",
    "CREATED_AT",
    "UPDATED_AT",
    "ITERATION",
    "MAX_ITERATIONS",
    "MODEL",
    "PROFILE",
    "SANDBOX_MODE",
    "APPROVAL_POLICY",
    "PID",
    "LAST_EXIT_CODE",
    "LAST_OUTPUT_FILE",
    "CONSECUTIVE_ERRORS",
    "CONSECUTIVE_ERROR_LIMIT",
    "SCRIPT_VERSION"
  ]);
}

async function readCampaignState(campaignDir) {
  return sourceStateFile(path.join(campaignDir, "state.env"), [
    "CAMPAIGN_ID",
    "STATUS",
    "WORKSPACE",
    "CREATED_AT",
    "UPDATED_AT",
    "ROUND",
    "CURRENT_LOOP_ID",
    "MAX_ROUNDS",
    "LOOP_MAX_ITERATIONS",
    "MODEL",
    "PROFILE",
    "SANDBOX_MODE",
    "APPROVAL_POLICY",
    "CONSECUTIVE_ERROR_LIMIT",
    "PID",
    "LAST_VERIFY_EXIT_CODE",
    "LAST_VERIFY_LOG",
    "VERIFY_CMD",
    "BOUNDARY_DOC",
    "BOUNDARY_SECTION",
    "LAST_BOUNDARY_COUNT",
    "BOUNDARY_SNAPSHOT_FILE",
    "PROMISE_PREFIX",
    "GOAL_FILE",
    "SCRIPT_VERSION"
  ]);
}

async function readIterationSummaries(iterationsRoot, limit = 20, options = {}) {
  const ids = await listDirectoriesNewestFirst(iterationsRoot);
  const selected = Number.isFinite(limit) ? ids.slice(0, limit) : ids;
  return Promise.all(selected.map((iterationId) => readIterationSummary(iterationsRoot, iterationId, options)));
}

async function readIterationSummary(iterationsRoot, iterationId, options) {
  const iterationDir = path.join(iterationsRoot, iterationId);
  const detailed = Boolean(options?.detailed);
  const currentWorkspace = options?.currentWorkspace || defaultWorkspace;

  const baseReads = [
    readTrimmed(path.join(iterationDir, "started-at.txt")),
    readTrimmed(path.join(iterationDir, "ended-at.txt")),
    readTrimmed(path.join(iterationDir, "exit-code.txt")),
    readTail(path.join(iterationDir, "final-message.txt"), 120)
  ];

  const detailReads = detailed
    ? [
        readTail(path.join(iterationDir, "stderr.txt"), 220),
        readTail(path.join(iterationDir, "session-output.txt"), 180),
        readTrimmed(path.join(iterationDir, "prompt.md")),
        readTrimmed(path.join(iterationDir, "task.md"))
      ]
    : [];

  const values = await Promise.all([...baseReads, ...detailReads]);
  const [startedAt, endedAt, exitCode, finalMessage, stderrTail = "", sessionTail = "", promptPreview = "", taskPreview = ""] = values;

  const fileRefs = aggregateFileRefs(
    currentWorkspace,
    [
      { source: `${iterationId}:closeout`, text: finalMessage },
      { source: `${iterationId}:stderr`, text: stderrTail },
      { source: `${iterationId}:session`, text: sessionTail },
      { source: `${iterationId}:prompt`, text: promptPreview },
      { source: `${iterationId}:task`, text: taskPreview }
    ],
    40
  );

  return {
    id: iterationId,
    startedAt,
    endedAt,
    exitCode,
    isInFlight: !endedAt && !finalMessage,
    finalMessage,
    stderrTail,
    sessionTail,
    promptPreview: truncate(promptPreview, 4600),
    taskPreview: truncate(taskPreview, 2800),
    fileRefs
  };
}

function buildOverviewSummary({ loops, campaigns, activeLoopId, activeCampaignId, workspaceBoundaries }) {
  const activeLoop = loops.find((loop) => loop.id === activeLoopId) ?? loops[0] ?? null;
  const activeCampaign = campaigns.find((campaign) => campaign.id === activeCampaignId) ?? campaigns[0] ?? null;

  return {
    missionHeadline:
      activeLoop?.taskHeadline ||
      activeCampaign?.goalHeadline ||
      "No active mission in this workspace.",
    activeStatus: activeLoop?.status || activeCampaign?.status || "idle",
    activeLoopId: activeLoop?.id || "",
    activeCampaignId: activeCampaign?.id || "",
    totalLoops: loops.length,
    totalCampaigns: campaigns.length,
    completedLoops: loops.filter((loop) => loop.status === "completed").length,
    runningLoops: loops.filter((loop) => loop.status === "running").length,
    failedLoops: loops.filter((loop) => ["failed", "cancelled"].includes(loop.status)).length,
    totalIterations: loops.reduce((sum, loop) => sum + (Number.isFinite(loop.iteration) ? loop.iteration : 0), 0),
    remainingBoundaries: workspaceBoundaries?.count ?? (activeCampaign ? Number(activeCampaign.remainingBoundaries || 0) : null),
    updatedAt: activeLoop?.updatedAt || activeCampaign?.updatedAt || "",
    currentIterationId: activeLoop?.latestIteration?.id || ""
  };
}

function buildActivityFeed({ loops, campaigns, activeLoopId, activeCampaignId }) {
  const items = [];

  for (const loop of loops) {
    if (!loop.latestIteration) continue;
    items.push({
      kind: "loop",
      id: `${loop.id}:${loop.latestIteration.id}`,
      scopeId: loop.id,
      title: loop.taskHeadline || loop.id,
      label: loop.id,
      status: loop.latestIteration.isInFlight ? "in-flight" : loop.status,
      timestamp: loop.latestIteration.endedAt || loop.latestIteration.startedAt || loop.updatedAt || loop.createdAt,
      summary:
        loop.latestIteration.isInFlight
          ? truncate(loop.latestIteration.stderrPreview || "Iteration is still in flight.", 260)
          : truncate(loop.latestCompletedMessage || loop.taskPreview || "", 260),
      active: loop.id === activeLoopId
    });
  }

  for (const campaign of campaigns) {
    items.push({
      kind: "campaign",
      id: campaign.id,
      scopeId: campaign.id,
      title: campaign.goalHeadline || campaign.id,
      label: campaign.id,
      status: campaign.status,
      timestamp: campaign.updatedAt || campaign.createdAt,
      summary: truncate(campaign.lastVerifyLogPreview || campaign.boundarySnapshotPreview || campaign.goalPreview || "", 260),
      active: campaign.id === activeCampaignId
    });
  }

  items.sort((left, right) => timestampValue(right.timestamp) - timestampValue(left.timestamp));
  return items.slice(0, 40);
}

async function readWorkspaceBoundarySnapshot(currentWorkspace) {
  const publicReleasePath = path.join(currentWorkspace, "docs", "public-release.md");
  const text = await readTrimmed(publicReleasePath);
  if (!text) return null;

  const lines = text.split("\n");
  const sectionStart = lines.findIndex((line) => /^##\s+Current Boundaries\b/i.test(line.trim()));
  if (sectionStart === -1) return null;

  const items = [];
  const noteLines = [];

  for (let index = sectionStart + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();
    if (/^##\s+/.test(trimmed)) break;
    if (/^\-\s+/.test(trimmed)) {
      items.push(trimmed.replace(/^\-\s+/, ""));
      continue;
    }
    if (trimmed) noteLines.push(trimmed);
  }

  return {
    source: path.relative(currentWorkspace, publicReleasePath) || publicReleasePath,
    count: items.length,
    items,
    note: noteLines.join(" ")
  };
}

function aggregateFileRefs(currentWorkspace, sources, limit = 60) {
  const map = new Map();

  for (const source of sources) {
    for (const ref of extractFileRefs(currentWorkspace, source.text || "")) {
      const existing = map.get(ref.absPath) || {
        absPath: ref.absPath,
        relativePath: ref.relativePath,
        category: ref.category,
        mentions: 0,
        sources: new Set()
      };
      existing.mentions += 1;
      existing.sources.add(source.source);
      map.set(ref.absPath, existing);
    }
  }

  return Array.from(map.values())
    .map((entry) => ({
      absPath: entry.absPath,
      relativePath: entry.relativePath,
      category: entry.category,
      mentions: entry.mentions,
      sources: Array.from(entry.sources).sort()
    }))
    .sort((left, right) => right.mentions - left.mentions || left.relativePath.localeCompare(right.relativePath))
    .slice(0, limit);
}

function extractFileRefs(currentWorkspace, text) {
  if (!text) return [];
  const refs = new Map();

  const candidates = [];
  const markdownLinkPattern = /\[[^\]]+\]\((\/[^)\s#]+(?:#[^)]+)?)\)/g;
  const rawPathPattern = /(\/(?:Users|private|tmp|var)\/[^\s`"'()<>{}\]]+)/g;

  for (const match of text.matchAll(markdownLinkPattern)) {
    if (match[1]) candidates.push(match[1]);
  }
  for (const match of text.matchAll(rawPathPattern)) {
    if (match[1]) candidates.push(match[1]);
  }

  for (const rawCandidate of candidates) {
    const normalized = normalizeFileRef(currentWorkspace, rawCandidate);
    if (!normalized) continue;
    refs.set(normalized.absPath, normalized);
  }

  return Array.from(refs.values());
}

function normalizeFileRef(currentWorkspace, rawCandidate) {
  const clean = rawCandidate
    .replace(/[#?].*$/, "")
    .replace(/[),.;]+$/, "")
    .trim();
  if (!clean.startsWith("/")) return null;

  const resolved = path.resolve(clean);
  let relativePath = resolved.startsWith(currentWorkspace) ? path.relative(currentWorkspace, resolved) : resolved;
  if (!relativePath || relativePath === ".") return null;
  if (relativePath.includes("node_modules")) return null;

  const normalizedRelative = relativePath.replace(/\\/g, "/");
  const category = normalizedRelative.startsWith(".ralph/")
    ? "artifacts"
    : normalizedRelative.startsWith("src/")
      ? "source"
      : normalizedRelative.startsWith("test/")
        ? "test"
        : normalizedRelative.startsWith("docs/")
          ? "docs"
          : "other";

  return {
    absPath: resolved,
    relativePath: normalizedRelative,
    category
  };
}

async function listDirectoriesNewestFirst(root) {
  try {
    const entries = await fs.readdir(root, { withFileTypes: true });
    const directories = await Promise.all(
      entries
        .filter((entry) => entry.isDirectory())
        .map(async (entry) => {
          const fullPath = path.join(root, entry.name);
          const stat = await fs.stat(fullPath);
          return { name: entry.name, mtimeMs: stat.mtimeMs };
        })
    );
    directories.sort((a, b) => b.mtimeMs - a.mtimeMs || b.name.localeCompare(a.name));
    return directories.map((entry) => entry.name);
  } catch {
    return [];
  }
}

async function fileExists(candidate) {
  try {
    await fs.stat(candidate);
    return true;
  } catch {
    return false;
  }
}

async function readTrimmed(filePath) {
  if (!filePath) return "";
  try {
    const text = await fs.readFile(filePath, "utf8");
    return text.replace(/\r/g, "").trimEnd();
  } catch {
    return "";
  }
}

async function readTail(filePath, maxLines) {
  const text = await readTrimmed(filePath);
  if (!text) return "";
  const lines = text.split("\n");
  return lines.slice(-maxLines).join("\n");
}

async function sourceStateFile(stateFile, fields) {
  try {
    const script = [
      "set -euo pipefail",
      'source "$1"',
      ...fields.map((field) => `printf '%s\\0' "\${${field}:-}"`)
    ].join("\n");
    const { stdout } = await execFileAsync("bash", ["-lc", script, "bash", stateFile], {
      encoding: "buffer",
      maxBuffer: 1024 * 1024
    });
    const values = stdout.toString("utf8").split("\0");
    const result = {};
    for (let index = 0; index < fields.length; index += 1) {
      result[fields[index]] = values[index] ?? "";
    }
    return result;
  } catch {
    return null;
  }
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      result[key] = true;
      continue;
    }
    result[key] = next;
    index += 1;
  }
  return result;
}

function truncate(text, maxChars) {
  if (!text) return "";
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars - 1)}…`;
}

function extractHeadline(text, fallback = "") {
  if (!text) return fallback;
  const lines = text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  const ignored = ["current context:", "first inspect:", "mission:", "rules:", "done", "open", "next"];
  for (const line of lines) {
    const normalized = line.toLowerCase();
    if (ignored.some((prefix) => normalized.startsWith(prefix))) continue;
    return truncate(line.replace(/^[-*#>\s]+/, ""), 160);
  }
  return truncate(lines[0] || fallback, 160);
}

function timestampValue(value) {
  const parsed = Date.parse(value || "");
  return Number.isFinite(parsed) ? parsed : 0;
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(payload));
}

function sendHtml(response, html) {
  response.writeHead(200, {
    "content-type": "text/html; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(html);
}

function renderDashboardHtml() {
  return String.raw`<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Ralph Mission Control</title>
    <style>
      :root {
        --bg: oklch(0.17 0.015 260);
        --bg-2: oklch(0.2 0.015 260);
        --panel: oklch(0.22 0.018 260);
        --panel-2: oklch(0.255 0.02 260);
        --panel-3: oklch(0.29 0.024 260);
        --ink: oklch(0.92 0.01 250);
        --muted: oklch(0.7 0.015 250);
        --line: oklch(0.37 0.02 255);
        --line-strong: oklch(0.5 0.03 245);
        --accent: oklch(0.78 0.15 154);
        --accent-blue: oklch(0.73 0.13 247);
        --accent-amber: oklch(0.78 0.15 92);
        --accent-red: oklch(0.67 0.18 29);
        --shadow: 0 24px 70px color-mix(in oklab, black 50%, transparent);
      }

      * {
        box-sizing: border-box;
      }

      html,
      body {
        width: 100%;
        height: 100%;
      }

      body {
        margin: 0;
        overflow: hidden;
        background:
          radial-gradient(circle at 18% 0%, color-mix(in oklab, var(--accent-blue) 18%, transparent), transparent 24%),
          radial-gradient(circle at 100% 12%, color-mix(in oklab, var(--accent) 16%, transparent), transparent 20%),
          linear-gradient(180deg, color-mix(in oklab, var(--bg-2) 92%, black) 0%, var(--bg) 100%);
        color: var(--ink);
        font-family: "Avenir Next", "Segoe UI", sans-serif;
      }

      .app-shell {
        width: 100vw;
        height: 100vh;
        padding: 10px;
      }

      .window {
        width: 100%;
        height: 100%;
        border-radius: 20px;
        overflow: hidden;
        border: 1px solid color-mix(in oklab, var(--line) 86%, transparent);
        background:
          linear-gradient(180deg, color-mix(in oklab, var(--panel) 94%, black) 0%, color-mix(in oklab, var(--bg) 96%, black) 100%);
        box-shadow: var(--shadow);
        display: grid;
        grid-template-rows: 56px 48px minmax(0, 1fr);
      }

      .topbar {
        display: grid;
        grid-template-columns: 120px minmax(0, 1fr) 340px;
        gap: 16px;
        align-items: center;
        padding: 0 18px;
        border-bottom: 1px solid color-mix(in oklab, var(--line) 78%, transparent);
        background: color-mix(in oklab, var(--panel) 90%, black);
      }

      .window-controls {
        display: flex;
        align-items: center;
        gap: 10px;
      }

      .window-dot {
        width: 14px;
        height: 14px;
        border-radius: 999px;
        background: color-mix(in oklab, var(--ink) 14%, var(--panel-3));
      }

      .window-dot.red { background: color-mix(in oklab, var(--accent-red) 78%, white); }
      .window-dot.amber { background: color-mix(in oklab, var(--accent-amber) 82%, white); }
      .window-dot.green { background: color-mix(in oklab, var(--accent) 82%, white); }

      .titlebar {
        min-width: 0;
        text-align: center;
      }

      .titlebar .title {
        font-family: "SF Mono", "Cascadia Code", monospace;
        font-size: 16px;
        letter-spacing: 0.04em;
        font-weight: 700;
      }

      .titlebar .subtitle {
        margin-top: 4px;
        color: var(--muted);
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.16em;
      }

      .header-actions {
        display: flex;
        align-items: center;
        justify-content: flex-end;
        gap: 10px;
      }

      .search {
        flex: 1 1 auto;
        max-width: 220px;
        border-radius: 999px;
        border: 1px solid color-mix(in oklab, var(--line-strong) 62%, transparent);
        background: color-mix(in oklab, var(--panel-2) 92%, black);
        color: var(--ink);
        padding: 10px 14px;
        font: inherit;
        outline: none;
      }

      .search::placeholder {
        color: color-mix(in oklab, var(--muted) 78%, transparent);
      }

      .mini-button,
      .tab-button,
      .workspace-card,
      .loop-card,
      .file-row,
      .iteration-chip,
      .artifact-toggle,
      .composer-button {
        border: 1px solid color-mix(in oklab, var(--line) 78%, transparent);
        background: color-mix(in oklab, var(--panel-2) 88%, black);
        color: inherit;
        cursor: pointer;
        transition: transform 140ms ease, border-color 140ms ease, background 140ms ease;
      }

      .mini-button:hover,
      .tab-button:hover,
      .workspace-card:hover,
      .loop-card:hover,
      .file-row:hover,
      .iteration-chip:hover,
      .artifact-toggle:hover,
      .composer-button:hover {
        transform: translateY(-1px);
        border-color: color-mix(in oklab, var(--accent-blue) 28%, var(--line));
      }

      .mini-button {
        border-radius: 999px;
        padding: 9px 12px;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
      }

      .mini-button.live {
        color: color-mix(in oklab, var(--accent) 86%, white);
        border-color: color-mix(in oklab, var(--accent) 35%, var(--line));
      }

      .tabbar {
        display: flex;
        gap: 2px;
        align-items: center;
        padding: 0 10px;
        border-bottom: 1px solid color-mix(in oklab, var(--line) 76%, transparent);
        background: color-mix(in oklab, var(--panel) 92%, black);
      }

      .tab-button {
        border: 0;
        border-bottom: 2px solid transparent;
        border-radius: 0;
        background: transparent;
        padding: 0 16px;
        height: 100%;
        color: color-mix(in oklab, var(--muted) 88%, transparent);
        font-size: 13px;
        font-family: "SF Mono", "Cascadia Code", monospace;
        text-transform: lowercase;
      }

      .tab-button.active {
        border-bottom-color: var(--accent-blue);
        color: var(--ink);
      }

      .layout {
        min-height: 0;
        display: grid;
        grid-template-columns: 320px minmax(0, 1fr) 360px;
        gap: 12px;
        padding: 12px;
      }

      .rail,
      .stage,
      .inspector {
        min-height: 0;
        display: grid;
        gap: 12px;
      }

      .rail {
        grid-template-rows: 168px minmax(0, 1fr) 180px;
      }

      .stage {
        grid-template-rows: 182px minmax(0, 1fr);
      }

      .inspector {
        grid-template-rows: 160px minmax(0, 1fr) 220px;
      }

      .panel {
        min-height: 0;
        border-radius: 18px;
        border: 1px solid color-mix(in oklab, var(--line) 82%, transparent);
        background:
          linear-gradient(180deg, color-mix(in oklab, var(--panel-2) 92%, black) 0%, color-mix(in oklab, var(--panel) 96%, black) 100%);
        overflow: hidden;
        display: grid;
        grid-template-rows: auto minmax(0, 1fr);
      }

      .panel-header {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        gap: 12px;
        padding: 14px 16px 12px;
        border-bottom: 1px solid color-mix(in oklab, var(--line) 70%, transparent);
      }

      .panel-title {
        margin: 0;
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.16em;
        color: var(--muted);
        font-family: "SF Mono", "Cascadia Code", monospace;
      }

      .panel-status {
        font-size: 11px;
        color: var(--muted);
        text-transform: uppercase;
        letter-spacing: 0.14em;
      }

      .panel-body {
        min-height: 0;
        padding: 14px 16px 16px;
        overflow: auto;
      }

      .mission-grid {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 12px;
        height: 100%;
      }

      .stat-card {
        border-radius: 18px;
        padding: 16px;
        border: 1px solid color-mix(in oklab, var(--line) 72%, transparent);
        background:
          linear-gradient(180deg, color-mix(in oklab, var(--panel-3) 84%, black) 0%, color-mix(in oklab, var(--panel-2) 92%, black) 100%);
      }

      .stat-card .label {
        display: block;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.16em;
        color: var(--muted);
        font-family: "SF Mono", "Cascadia Code", monospace;
      }

      .stat-card .value {
        margin-top: 12px;
        font-size: clamp(28px, 2.3vw, 42px);
        line-height: 0.92;
        font-weight: 760;
      }

      .stat-card .subvalue {
        margin-top: 10px;
        font-size: 13px;
        color: color-mix(in oklab, var(--accent) 86%, white);
      }

      .summary-copy {
        font-size: 14px;
        line-height: 1.6;
        color: color-mix(in oklab, var(--ink) 90%, black);
      }

      .status-badges {
        display: flex;
        flex-wrap: wrap;
        gap: 8px;
        margin-top: 12px;
      }

      .badge {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        border-radius: 999px;
        padding: 7px 11px;
        border: 1px solid color-mix(in oklab, var(--line) 74%, transparent);
        background: color-mix(in oklab, var(--panel-3) 88%, black);
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
      }

      .badge.running { color: color-mix(in oklab, var(--accent-blue) 82%, white); }
      .badge.completed { color: color-mix(in oklab, var(--accent) 82%, white); }
      .badge.failed,
      .badge.cancelled { color: color-mix(in oklab, var(--accent-red) 84%, white); }
      .badge.warning { color: color-mix(in oklab, var(--accent-amber) 88%, white); }

      .cards-stack,
      .files-list,
      .feed-list,
      .notifications-list,
      .boundaries-list {
        display: grid;
        gap: 10px;
      }

      .workspace-card,
      .loop-card {
        width: 100%;
        text-align: left;
        border-radius: 16px;
        padding: 14px;
      }

      .workspace-card.active,
      .loop-card.active,
      .file-row.active,
      .iteration-chip.active,
      .artifact-toggle.active,
      .composer-button.primary {
        border-color: color-mix(in oklab, var(--accent-blue) 36%, var(--line));
        background:
          linear-gradient(180deg, color-mix(in oklab, var(--accent-blue) 12%, var(--panel-3)) 0%, color-mix(in oklab, var(--panel-2) 92%, black) 100%);
      }

      .workspace-head,
      .loop-head,
      .feed-head,
      .notification-head {
        display: flex;
        justify-content: space-between;
        gap: 10px;
        align-items: baseline;
      }

      .workspace-name,
      .loop-name,
      .feed-title,
      .notification-title {
        font-size: 15px;
        font-weight: 700;
      }

      .workspace-meta,
      .loop-meta,
      .feed-copy,
      .notification-copy,
      .tiny {
        color: var(--muted);
        font-size: 12px;
        line-height: 1.5;
      }

      .stream-console,
      .mission-console,
      .files-console,
      .workspace-console,
      .notifications-console {
        min-height: 0;
        display: none;
      }

      .stream-console.active,
      .mission-console.active,
      .files-console.active,
      .workspace-console.active,
      .notifications-console.active {
        display: grid;
      }

      .stream-console {
        grid-template-rows: 72px minmax(0, 1fr);
      }

      .mission-console,
      .files-console,
      .workspace-console,
      .notifications-console {
        grid-template-rows: minmax(0, 1fr);
      }

      .stream-top {
        display: grid;
        grid-template-columns: 1.15fr 0.85fr;
        gap: 12px;
      }

      .stream-chipbox,
      .stream-status-box {
        border-radius: 16px;
        border: 1px solid color-mix(in oklab, var(--line) 72%, transparent);
        background: color-mix(in oklab, var(--panel-3) 86%, black);
        padding: 12px 14px;
      }

      .stream-status-box strong {
        display: block;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
        margin-bottom: 8px;
      }

      .console {
        min-height: 0;
        border-radius: 16px;
        border: 1px solid color-mix(in oklab, var(--line) 72%, transparent);
        background:
          linear-gradient(180deg, color-mix(in oklab, black 78%, var(--panel-2)) 0%, color-mix(in oklab, black 90%, var(--panel)) 100%);
        padding: 14px 16px;
        overflow: auto;
      }

      .console-line {
        display: grid;
        grid-template-columns: 72px minmax(0, 1fr);
        gap: 12px;
        padding: 4px 0;
        font-family: "SF Mono", "Cascadia Code", monospace;
        font-size: 13px;
        line-height: 1.5;
      }

      .console-time {
        color: color-mix(in oklab, var(--muted) 78%, transparent);
      }

      .console-body {
        color: color-mix(in oklab, var(--ink) 92%, black);
        white-space: pre-wrap;
        word-break: break-word;
      }

      .console-body.done { color: color-mix(in oklab, var(--accent) 84%, white); }
      .console-body.open { color: color-mix(in oklab, var(--accent-amber) 82%, white); }
      .console-body.next { color: color-mix(in oklab, var(--accent-blue) 82%, white); }
      .console-body.warning { color: color-mix(in oklab, var(--accent-red) 82%, white); }

      .mission-layout,
      .workspace-grid {
        display: grid;
        gap: 12px;
        grid-template-columns: 1.05fr 0.95fr;
        min-height: 0;
      }

      .section-card {
        min-height: 0;
        border-radius: 16px;
        border: 1px solid color-mix(in oklab, var(--line) 74%, transparent);
        background: color-mix(in oklab, var(--panel-2) 90%, black);
        padding: 14px;
        overflow: auto;
      }

      .section-card h3 {
        margin: 0 0 10px;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
        font-family: "SF Mono", "Cascadia Code", monospace;
      }

      .section-card pre {
        margin: 0;
        white-space: pre-wrap;
        word-break: break-word;
        font: 12px/1.56 "SF Mono", "Cascadia Code", monospace;
        color: color-mix(in oklab, var(--ink) 92%, black);
      }

      .closeout-stack {
        display: grid;
        gap: 10px;
      }

      .closeout-box {
        padding: 12px 13px;
        border-radius: 14px;
        border: 1px solid color-mix(in oklab, var(--line) 72%, transparent);
        background: color-mix(in oklab, var(--panel-3) 84%, black);
      }

      .closeout-box h4 {
        margin: 0 0 8px;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
      }

      .closeout-box ul {
        margin: 0;
        padding-left: 18px;
        display: grid;
        gap: 6px;
      }

      .file-row {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 12px;
        align-items: center;
        width: 100%;
        text-align: left;
        border-radius: 14px;
        padding: 12px 13px;
      }

      .file-row .path {
        font-family: "SF Mono", "Cascadia Code", monospace;
        font-size: 13px;
        line-height: 1.5;
      }

      .file-row .category {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
      }

      .inspector-grid {
        display: grid;
        gap: 12px;
      }

      .iteration-strip {
        display: flex;
        gap: 8px;
        overflow-x: auto;
      }

      .iteration-chip {
        min-width: 128px;
        text-align: left;
        border-radius: 16px;
        padding: 11px 12px;
      }

      .iteration-chip strong {
        display: block;
        font-size: 13px;
        font-family: "SF Mono", "Cascadia Code", monospace;
      }

      .iteration-chip span {
        display: block;
        margin-top: 7px;
        color: var(--muted);
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.12em;
      }

      .artifact-switch {
        display: flex;
        gap: 8px;
        flex-wrap: wrap;
      }

      .artifact-toggle {
        border-radius: 999px;
        padding: 8px 12px;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
      }

      .notification-toast-stack {
        position: fixed;
        right: 20px;
        bottom: 18px;
        width: min(360px, calc(100vw - 24px));
        display: grid;
        gap: 10px;
        pointer-events: none;
      }

      .toast {
        border-radius: 16px;
        padding: 12px 14px;
        border: 1px solid color-mix(in oklab, var(--line-strong) 74%, transparent);
        background: color-mix(in oklab, var(--panel-3) 92%, black);
        box-shadow: 0 18px 34px color-mix(in oklab, black 44%, transparent);
      }

      .toast strong {
        display: block;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
        margin-bottom: 6px;
      }

      .composer-form {
        display: grid;
        gap: 10px;
      }

      .composer-grid {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 10px;
      }

      .composer-field {
        display: grid;
        gap: 6px;
      }

      .composer-field label {
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
        color: var(--muted);
        font-family: "SF Mono", "Cascadia Code", monospace;
      }

      .composer-field input,
      .composer-field select,
      .composer-field textarea {
        width: 100%;
        border-radius: 14px;
        border: 1px solid color-mix(in oklab, var(--line-strong) 60%, transparent);
        background: color-mix(in oklab, var(--panel-3) 88%, black);
        color: var(--ink);
        font: inherit;
        padding: 10px 12px;
        outline: none;
        resize: none;
      }

      .composer-field textarea {
        min-height: 92px;
      }

      .composer-actions {
        display: flex;
        gap: 8px;
        flex-wrap: wrap;
      }

      .composer-button {
        border-radius: 999px;
        padding: 10px 14px;
        font-size: 11px;
        text-transform: uppercase;
        letter-spacing: 0.14em;
      }

      .composer-preview {
        border-radius: 14px;
        border: 1px solid color-mix(in oklab, var(--line) 72%, transparent);
        background: color-mix(in oklab, black 74%, var(--panel));
        padding: 12px;
        overflow: auto;
      }

      .composer-preview pre {
        margin: 0;
        white-space: pre-wrap;
        word-break: break-word;
        font: 12px/1.55 "SF Mono", "Cascadia Code", monospace;
      }

      .empty {
        border-radius: 14px;
        border: 1px dashed color-mix(in oklab, var(--line) 74%, transparent);
        padding: 14px;
        color: var(--muted);
      }

      /* Mission Control v3: pure-black, lower-noise, cockpit-first overrides */
      :root {
        --bg: #000000;
        --bg-2: #010101;
        --panel: #040404;
        --panel-2: #070707;
        --panel-3: #0b0b0b;
        --ink: #f2f2f2;
        --muted: #8c8c8c;
        --line: #171717;
        --line-strong: #232323;
        --accent: #88ffb0;
        --accent-blue: #d8d8d8;
        --accent-amber: #c6c6c6;
        --accent-red: #ff7d7d;
        --shadow: none;
      }

      body {
        background: #000;
        font-family: "SF Mono", "IBM Plex Mono", "Cascadia Code", monospace;
      }

      .app-shell {
        padding: 0;
      }

      .window {
        border-radius: 0;
        border: 1px solid var(--line);
        background: #000;
        box-shadow: none;
        grid-template-rows: 54px 48px minmax(0, 1fr);
      }

      .topbar,
      .tabbar {
        background: #050505;
        border-bottom-color: var(--line);
      }

      .topbar {
        grid-template-columns: 100px minmax(0, 1fr) 320px;
      }

      .titlebar .title {
        font-size: 15px;
        letter-spacing: 0.06em;
      }

      .titlebar .subtitle {
        color: #676767;
      }

      .window-dot {
        width: 15px;
        height: 15px;
      }

      .search,
      .mini-button,
      .workspace-card,
      .loop-card,
      .file-row,
      .iteration-chip,
      .artifact-toggle,
      .composer-button,
      .badge {
        border-radius: 4px;
      }

      .search {
        max-width: 240px;
        border-color: var(--line-strong);
        background: #090909;
      }

      .mini-button {
        background: #080808;
        color: #b8b8b8;
      }

      .mini-button.live {
        color: var(--accent);
        border-color: #1b2a20;
      }

      .tabbar {
        gap: 0;
        padding: 0 14px;
      }

      .tab-button {
        font-size: 12px;
        color: #7d7d7d;
      }

      .tab-button.active {
        color: #f4f4f4;
        border-bottom-color: #f4f4f4;
      }

      .layout {
        gap: 12px;
        padding: 12px;
        background: #000;
        grid-template-columns: 252px minmax(0, 1fr) 300px;
      }

      .rail,
      .stage,
      .inspector {
        gap: 12px;
        background: transparent;
      }

      .rail {
        grid-template-rows: 126px minmax(0, 1fr);
      }

      .stage {
        grid-template-rows: 92px minmax(0, 1fr);
      }

      .inspector {
        grid-template-rows: 96px 206px minmax(0, 1fr);
      }

      .rail > .panel:nth-child(3),
      .inspector > .panel:nth-child(3),
      #workspace-strip {
        display: none;
      }

      .panel {
        border: 1px solid var(--line);
        border-radius: 6px;
        background: #050505;
      }

      .panel-header {
        padding: 13px 16px 11px;
        border-bottom-color: var(--line);
      }

      .panel-title,
      .panel-status {
        font-size: 11px;
        letter-spacing: 0.18em;
      }

      .panel-body {
        padding: 16px;
      }

      .mission-grid {
        grid-template-columns: 1fr;
        gap: 0;
      }

      .stat-card {
        border-radius: 0;
        padding: 0;
        border: 0;
        background: transparent;
      }

      .signal-strip {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        gap: 0;
        background: transparent;
        border: 1px solid var(--line);
      }

      .signal-row {
        min-width: 0;
        background: #020202;
        padding: 14px 16px 13px;
        border-left: 1px solid var(--line);
      }

      .signal-row:first-child {
        border-left: 0;
      }

      .signal-key {
        display: block;
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: 0.16em;
        color: #7d7d7d;
        margin-bottom: 10px;
      }

      .signal-value {
        display: block;
        font-size: 15px;
        line-height: 1.45;
        color: #f2f2f2;
        word-break: break-word;
      }

      .signal-value.emphasis {
        font-size: 16px;
        color: var(--accent);
      }

      .summary-copy,
      .loop-meta,
      .feed-copy,
      .notification-copy,
      .tiny {
        color: #8d8d8d;
      }

      .summary-copy {
        font-size: 14px;
        line-height: 1.8;
        display: -webkit-box;
        -webkit-box-orient: vertical;
        overflow: hidden;
        -webkit-line-clamp: 4;
      }

      .status-badges {
        gap: 6px;
        margin-top: 10px;
      }

      .badge {
        padding: 6px 8px;
        border-color: var(--line);
        background: #090909;
        color: #d8d8d8;
      }

      .badge.running,
      .console-body.next,
      .signal-value.live {
        color: var(--accent);
      }

      .badge.warning,
      .console-body.open {
        color: #d0d0d0;
      }

      .badge.failed,
      .badge.cancelled,
      .console-body.warning {
        color: var(--accent-red);
      }

      .workspace-card,
      .loop-card,
      .file-row,
      .iteration-chip,
      .artifact-toggle {
        background: #090909;
        border-color: var(--line);
        border-radius: 0;
      }

      .workspace-card.active,
      .loop-card.active,
      .file-row.active,
      .iteration-chip.active,
      .artifact-toggle.active,
      .composer-button.primary {
        background: #111111;
        border-color: #2b2b2b;
      }

      .loop-name,
      .workspace-name,
      .feed-title,
      .notification-title {
        font-size: 13px;
      }

      .loop-card {
        padding: 12px 13px;
      }

      .loop-meta {
        display: -webkit-box;
        -webkit-box-orient: vertical;
        overflow: hidden;
        -webkit-line-clamp: 2;
      }

      .stream-console {
        grid-template-rows: 62px minmax(0, 1fr);
      }

      .stream-top {
        grid-template-columns: 1fr;
        gap: 0;
        background: transparent;
        border: 0;
      }

      .stream-chipbox,
      .stream-status-box {
        border: 0;
        border-radius: 0;
        background: transparent;
        padding: 0;
      }

      .stream-status-box {
        display: none;
      }

      .telemetry-inline {
        display: grid;
        grid-template-columns: repeat(4, minmax(0, 1fr));
        border: 1px solid var(--line);
        background: #020202;
      }

      .telemetry-stat {
        min-width: 0;
        padding: 12px 14px;
        border-left: 1px solid var(--line);
      }

      .telemetry-stat:first-child {
        border-left: 0;
      }

      .telemetry-stat .key {
        display: block;
        margin-bottom: 9px;
        color: #7b7b7b;
        font-size: 10px;
        letter-spacing: 0.16em;
        text-transform: uppercase;
      }

      .telemetry-stat .value {
        display: block;
        color: #f2f2f2;
        font-size: 14px;
        line-height: 1.45;
        word-break: break-word;
      }

      .telemetry-stat .value.live {
        color: var(--accent);
      }

      .console {
        border-radius: 4px;
        border-color: var(--line);
        background: #000;
        padding: 16px 18px;
      }

      .console-line {
        grid-template-columns: 84px minmax(0, 1fr);
        gap: 16px;
        padding: 4px 0;
        font-size: 12px;
      }

      .console-time {
        color: #727272;
      }

      .console-body {
        color: #efefef;
      }

      .mission-layout,
      .workspace-grid {
        grid-template-columns: 1fr 1fr;
        gap: 1px;
        background: var(--line);
      }

      .section-card {
        border: 0;
        border-radius: 0;
        background: #050505;
        padding: 12px;
      }

      .closeout-box {
        border-radius: 0;
        border-color: var(--line);
        background: #090909;
      }

      .iteration-strip {
        display: grid;
        grid-template-columns: 1fr;
        gap: 8px;
        max-height: 220px;
        overflow: auto;
      }

      .iteration-chip {
        min-width: 0;
        width: 100%;
      }

      .artifact-switch {
        display: grid;
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 8px;
      }

      .artifact-toggle {
        padding: 7px 10px;
      }

      .focus-stack {
        display: grid;
        gap: 8px;
      }

      .focus-line {
        display: grid;
        grid-template-columns: 92px minmax(0, 1fr);
        gap: 10px;
        padding: 8px 0;
        border-top: 1px solid var(--line);
      }

      .focus-line:first-child {
        border-top: 0;
        padding-top: 0;
      }

      .focus-key {
        color: #6d6d6d;
        font-size: 10px;
        text-transform: uppercase;
        letter-spacing: 0.16em;
      }

      .focus-value {
        color: #f2f2f2;
        font-size: 13px;
        line-height: 1.55;
        word-break: break-word;
      }

      .focus-value.soft {
        color: #a4a4a4;
      }

      .window[data-view="stream"] .layout {
        grid-template-columns: 252px minmax(0, 1fr) 300px;
      }

      .window[data-view="stream"] .stage {
        grid-template-rows: 92px minmax(0, 1fr);
      }

      .window[data-view="stream"] .inspector {
        grid-template-rows: 96px 206px minmax(0, 1fr);
      }

      .empty {
        border-radius: 0;
        border-color: var(--line);
        background: #080808;
      }

      @media (max-width: 1440px) {
        .layout {
          grid-template-columns: 240px minmax(0, 1fr) 280px;
        }
      }

      @media (max-width: 1180px) {
        .layout {
          grid-template-columns: 1fr;
        }

        .rail,
        .stage,
        .inspector {
          grid-template-rows: none;
        }

        .mission-grid,
        .mission-layout,
        .workspace-grid,
        .stream-top,
        .composer-grid {
          grid-template-columns: 1fr;
        }
      }
    </style>
  </head>
  <body>
    <div class="app-shell">
      <div class="window">
        <header class="topbar">
          <div class="window-controls">
            <span class="window-dot red"></span>
            <span class="window-dot amber"></span>
            <span class="window-dot green"></span>
          </div>
          <div class="titlebar">
            <div class="title" id="window-title">ralph-mission-control</div>
            <div class="subtitle" id="window-subtitle">workspace mission terminal</div>
          </div>
          <div class="header-actions">
            <input class="search" id="global-filter" placeholder="filter loops, files, workspaces…" />
            <button class="mini-button" id="notification-permission">alerts</button>
            <button class="mini-button live" id="stream-state">live</button>
          </div>
        </header>

        <nav class="tabbar" id="tabbar">
          <button class="tab-button active" data-view="stream">terminal</button>
          <button class="tab-button" data-view="mission">mission</button>
          <button class="tab-button" data-view="files">files</button>
          <button class="tab-button" data-view="workspaces">workspaces</button>
          <button class="tab-button" data-view="notifications">notifications</button>
        </nav>

        <section class="layout">
          <aside class="rail">
            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Mission</h2>
                <div class="panel-status" id="snapshot-updated">live</div>
              </div>
              <div class="panel-body" id="mission-snapshot"></div>
            </section>

            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">History</h2>
                <div class="panel-status" id="loop-explorer-count">0 loops</div>
              </div>
              <div class="panel-body">
                <div class="cards-stack" id="workspace-strip"></div>
                <div style="height: 12px"></div>
                <div class="cards-stack" id="loop-list"></div>
              </div>
            </section>

            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Roadmap Radar</h2>
                <div class="panel-status" id="boundary-counter">0 boundaries</div>
              </div>
              <div class="panel-body">
                <div class="boundaries-list" id="boundary-list"></div>
              </div>
            </section>
          </aside>

          <main class="stage">
            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Current Signal</h2>
                <div class="panel-status" id="stage-label">active mission</div>
              </div>
              <div class="panel-body">
                <div class="mission-grid" id="mission-grid"></div>
              </div>
            </section>

            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title" id="view-title">Live Execution</h2>
                <div class="panel-status" id="view-meta">autorefresh</div>
              </div>
              <div class="panel-body" style="padding: 14px;">
                <section class="stream-console active" data-view-panel="stream">
                  <div class="stream-top">
                    <div class="stream-chipbox" id="stream-chipbox"></div>
                    <div class="stream-status-box">
                      <strong>Current live signal</strong>
                      <div id="stream-status-copy" class="summary-copy"></div>
                    </div>
                  </div>
                  <div class="console" id="stream-console"></div>
                </section>

                <section class="mission-console" data-view-panel="mission">
                  <div class="mission-layout">
                    <article class="section-card">
                      <h3>Mission Blueprint</h3>
                      <pre id="mission-blueprint"></pre>
                    </article>
                    <article class="section-card">
                      <h3>Handoff & Last Message</h3>
                      <pre id="mission-handoff"></pre>
                    </article>
                    <article class="section-card">
                      <h3>Closeout Sections</h3>
                      <div class="closeout-stack" id="closeout-stack"></div>
                    </article>
                    <article class="section-card">
                      <h3>Execution Feed</h3>
                      <div class="feed-list" id="activity-feed"></div>
                    </article>
                  </div>
                </section>

                <section class="files-console" data-view-panel="files">
                  <div class="mission-layout">
                    <article class="section-card">
                      <h3>Touched Files</h3>
                      <div class="files-list" id="files-list"></div>
                    </article>
                    <article class="section-card">
                      <h3>File Detail</h3>
                      <div id="file-detail"></div>
                    </article>
                  </div>
                </section>

                <section class="workspace-console" data-view-panel="workspaces">
                  <div class="workspace-grid" id="workspace-grid"></div>
                </section>

                <section class="notifications-console" data-view-panel="notifications">
                  <div class="mission-layout">
                    <article class="section-card">
                      <h3>Notification Log</h3>
                      <div class="notifications-list" id="notifications-log"></div>
                    </article>
                    <article class="section-card">
                      <h3>System Pulse</h3>
                      <div class="notifications-list" id="system-pulse"></div>
                    </article>
                  </div>
                </section>
              </div>
            </section>
          </main>

          <aside class="inspector">
            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Focus</h2>
                <div class="panel-status" id="selected-loop-meta">idle</div>
              </div>
              <div class="panel-body">
                <div class="summary-copy" id="selected-loop-headline"></div>
                <div class="status-badges" id="selected-loop-badges"></div>
              </div>
            </section>

            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Execution</h2>
                <div class="panel-status" id="iteration-meta-label">current</div>
              </div>
              <div class="panel-body">
                <div class="iteration-strip" id="iteration-strip"></div>
                <div style="height: 12px"></div>
                <div class="artifact-switch" id="artifact-switch"></div>
                <div style="height: 12px"></div>
                <div class="section-card" style="padding: 12px;">
                  <h3 id="artifact-title">Artifact</h3>
                  <div id="artifact-body"></div>
                </div>
              </div>
            </section>

            <section class="panel">
              <div class="panel-header">
                <h2 class="panel-title">Task Console</h2>
                <div class="panel-status">draft + copy</div>
              </div>
              <div class="panel-body">
                <form class="composer-form" id="composer-form">
                  <div class="composer-grid">
                    <div class="composer-field">
                      <label for="composer-mode">Mode</label>
                      <select id="composer-mode">
                        <option value="loop">loop</option>
                        <option value="campaign">campaign</option>
                      </select>
                    </div>
                    <div class="composer-field">
                      <label for="composer-promise">Promise</label>
                      <input id="composer-promise" value="SHIPIT" />
                    </div>
                    <div class="composer-field">
                      <label for="composer-max-iterations">Iterations</label>
                      <input id="composer-max-iterations" value="0" />
                    </div>
                    <div class="composer-field">
                      <label for="composer-verify">Verify</label>
                      <input id="composer-verify" value="npm run verify" />
                    </div>
                  </div>
                  <div class="composer-field">
                    <label for="composer-text">Mission Draft</label>
                    <textarea id="composer-text" placeholder="Describe the next mission…"></textarea>
                  </div>
                  <div class="composer-actions">
                    <button type="button" class="composer-button primary" id="copy-command">copy command</button>
                    <button type="button" class="composer-button" id="copy-prompt">copy prompt</button>
                  </div>
                  <div class="composer-preview">
                    <pre id="composer-preview"></pre>
                  </div>
                </form>
              </div>
            </section>
          </aside>
        </section>
      </div>
    </div>

    <div class="notification-toast-stack" id="toast-stack"></div>

    <script>
      const store = {
        currentWorkspace: "",
        overview: null,
        workspaces: [],
        loopDetails: new Map(),
        campaignDetails: new Map(),
        selectedLoopId: "",
        selectedCampaignId: "",
        selectedIterationId: "",
        selectedFilePath: "",
        selectedArtifact: "auto",
        selectedView: "stream",
        filterText: "",
        notifications: [],
        toasts: [],
        streamSource: null,
        streamState: "connecting",
        pinnedLoopSelection: false,
        pinnedIterationSelection: false,
        pinnedCampaignSelection: false,
        pinnedWorkspaceSelection: false,
        previousSnapshot: null
      };

      const escapeHtml = (value) =>
        String(value ?? "")
          .replaceAll("&", "&amp;")
          .replaceAll("<", "&lt;")
          .replaceAll(">", "&gt;");

      const truncateCopy = (value, maxChars = 160) => {
        const text = String(value ?? "");
        if (text.length <= maxChars) return text;
        return text.slice(0, maxChars - 1) + "…";
      };

      const fetchJson = async (url) => {
        const response = await fetch(url, { cache: "no-store" });
        if (!response.ok) {
          throw new Error("Request failed for " + url + " (" + response.status + ")");
        }
        return response.json();
      };

      const statusClass = (value) => {
        const normalized = String(value || "").toLowerCase();
        if (normalized === "completed") return "completed";
        if (["failed", "cancelled"].includes(normalized)) return "failed";
        if (["running", "stopped", "in-flight", "cancel-requested"].includes(normalized)) return "running";
        return "";
      };

      const shortDateTime = (value) => {
        if (!value) return "unknown";
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return value;
        return date.toLocaleString(undefined, {
          month: "short",
          day: "numeric",
          hour: "2-digit",
          minute: "2-digit"
        });
      };

      const shortTime = (value) => {
        if (!value) return "--:--";
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return value;
        return date.toLocaleTimeString(undefined, {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit"
        });
      };

      const compactCount = (value, singular, plural) => {
        const number = Number(value || 0);
        return number + " " + (number === 1 ? singular : plural);
      };

      const normalizeText = (value) => String(value || "").toLowerCase();

      const textMatchesFilter = (value) => {
        if (!store.filterText) return true;
        return normalizeText(value).includes(store.filterText);
      };

      const makeBadge = (label, value, className = "") =>
        '<span class="badge ' +
        statusClass(value) +
        (className ? " " + className : "") +
        '">' +
        escapeHtml(label) +
        ": " +
        escapeHtml(String(value ?? "")) +
        "</span>";

      const splitCloseoutSections = (text) => {
        if (!text) return [];
        const sections = [];
        let current = { title: "Summary", lines: [] };
        const pattern = /^\*\*(Done|Open|Next)\*\*$/i;
        for (const rawLine of String(text).split("\n")) {
          const line = rawLine.trimEnd();
          const trimmed = line.trim();
          const match = pattern.exec(trimmed);
          if (match) {
            if (current.lines.length || current.title !== "Summary") sections.push(current);
            current = { title: match[1], lines: [] };
            continue;
          }
          if (trimmed) current.lines.push(trimmed.replace(/^\-\s+/, ""));
        }
        if (current.lines.length || current.title !== "Summary") sections.push(current);
        return sections;
      };

      const iterationStatusLabel = (iteration) => {
        if (!iteration) return "idle";
        if (iteration.isInFlight) return "in-flight";
        if (iteration.exitCode) return "exit " + iteration.exitCode;
        return "completed";
      };

      const getSelectedLoopDetail = () => {
        if (!store.selectedLoopId) return null;
        return store.loopDetails.get(store.currentWorkspace + "::" + store.selectedLoopId) || null;
      };

      const getSelectedCampaignDetail = () => {
        if (!store.selectedCampaignId) return null;
        return store.campaignDetails.get(store.currentWorkspace + "::" + store.selectedCampaignId) || null;
      };

      const getSelectedIteration = () => {
        const detail = getSelectedLoopDetail();
        if (!detail) return null;
        return detail.iterations.find((iteration) => iteration.id === store.selectedIterationId) || detail.iterations[0] || null;
      };

      const currentArtifact = (iteration) => {
        if (!iteration) return "closeout";
        if (store.selectedArtifact !== "auto") return store.selectedArtifact;
        if (iteration.isInFlight && iteration.stderrTail) return "stderr";
        if (iteration.finalMessage) return "closeout";
        if (iteration.sessionTail) return "session";
        if (iteration.fileRefs?.length) return "files";
        if (iteration.promptPreview) return "prompt";
        return "task";
      };

      const notify = (title, message, level = "info") => {
        const entry = {
          id: String(Date.now()) + "-" + Math.random().toString(36).slice(2, 8),
          title,
          message,
          level,
          timestamp: new Date().toISOString()
        };
        store.notifications.unshift(entry);
        store.notifications = store.notifications.slice(0, 80);
        store.toasts.unshift(entry);
        store.toasts = store.toasts.slice(0, 4);
        renderToasts();

        if ("Notification" in window && Notification.permission === "granted") {
          try {
            new Notification(title, { body: message });
          } catch {}
        }

        setTimeout(() => {
          store.toasts = store.toasts.filter((toast) => toast.id !== entry.id);
          renderToasts();
        }, 6000);
      };

      const renderToasts = () => {
        document.querySelector("#toast-stack").innerHTML = store.toasts
          .map(
            (toast) =>
              '<div class="toast">' +
              "<strong>" +
              escapeHtml(toast.title) +
              "</strong>" +
              escapeHtml(toast.message) +
              "</div>"
          )
          .join("");
      };

      const trackOverviewChanges = (nextOverview) => {
        const previous = store.previousSnapshot;
        store.previousSnapshot = {
          activeLoopId: nextOverview.activeLoopId,
          activeStatus: nextOverview.summary.activeStatus,
          currentIterationId: nextOverview.summary.currentIterationId,
          remainingBoundaries: nextOverview.summary.remainingBoundaries
        };
        if (!previous) return;

        if (previous.activeLoopId !== nextOverview.activeLoopId) {
          notify("Active loop changed", nextOverview.activeLoopId || "No active loop");
        }
        if (previous.currentIterationId !== nextOverview.summary.currentIterationId) {
          notify("Iteration moved", "Now tracking iteration " + (nextOverview.summary.currentIterationId || "none"), "progress");
        }
        if (previous.activeStatus !== nextOverview.summary.activeStatus) {
          notify("Loop status changed", nextOverview.summary.activeStatus || "unknown", nextOverview.summary.activeStatus || "info");
        }
        if (previous.remainingBoundaries !== nextOverview.summary.remainingBoundaries) {
          notify(
            "Boundary count changed",
            "Remaining boundaries: " + String(nextOverview.summary.remainingBoundaries),
            "boundary"
          );
        }
      };

      const ensureSelection = () => {
        const overview = store.overview;
        if (!overview) return;

        if (!store.currentWorkspace) {
          store.currentWorkspace = overview.workspace;
        }

        if (!store.pinnedLoopSelection || !overview.loops.some((loop) => loop.id === store.selectedLoopId)) {
          store.selectedLoopId = overview.activeLoopId || overview.loops[0]?.id || "";
          store.pinnedLoopSelection = false;
        }

        if (!store.pinnedCampaignSelection || !overview.campaigns.some((campaign) => campaign.id === store.selectedCampaignId)) {
          store.selectedCampaignId = overview.activeCampaignId || overview.campaigns[0]?.id || "";
          store.pinnedCampaignSelection = false;
        }
      };

      const ensureIterationSelection = () => {
        const detail = getSelectedLoopDetail();
        if (!detail) return;
        if (!store.pinnedIterationSelection || !detail.iterations.some((iteration) => iteration.id === store.selectedIterationId)) {
          store.selectedIterationId = detail.currentIterationId || detail.iterations[0]?.id || "";
          store.pinnedIterationSelection = false;
        }
      };

      const ensureFileSelection = () => {
        const detail = getSelectedLoopDetail();
        if (!detail) return;
        if (!detail.files.length) {
          store.selectedFilePath = "";
          return;
        }
        if (!store.selectedFilePath || !detail.files.some((file) => file.absPath === store.selectedFilePath)) {
          store.selectedFilePath = detail.files[0].absPath;
        }
      };

      const filteredLoops = () => {
        const loops = store.overview?.loops || [];
        return loops.filter((loop) =>
          textMatchesFilter(loop.id + " " + loop.taskHeadline + " " + loop.taskPreview + " " + loop.latestCompletedMessage)
        );
      };

      const filteredWorkspaces = () => {
        return (store.workspaces || []).filter((workspace) =>
          textMatchesFilter(
            workspace.name +
              " " +
              workspace.path +
              " " +
              workspace.missionHeadline +
              " " +
              String(workspace.boundaryCount ?? "")
          )
        );
      };

      const filteredFiles = () => {
        const detail = getSelectedLoopDetail();
        if (!detail) return [];
        return detail.files.filter((file) =>
          textMatchesFilter(file.relativePath + " " + file.category + " " + file.sources.join(" "))
        );
      };

      const openEventStream = () => {
        if (store.streamSource) {
          store.streamSource.close();
        }

        const source = new EventSource("/events?workspace=" + encodeURIComponent(store.currentWorkspace || ""));
        store.streamSource = source;
        store.streamState = "live";
        updateStreamState();

        source.addEventListener("snapshot", async (event) => {
          try {
            const overview = JSON.parse(event.data);
            store.overview = overview;
            store.currentWorkspace = overview.workspace;
            trackOverviewChanges(overview);
            ensureSelection();
            await Promise.all([
              loadLoopDetail(store.selectedLoopId),
              loadCampaignDetail(store.selectedCampaignId),
              loadWorkspaces()
            ]);
            ensureIterationSelection();
            ensureFileSelection();
            render();
          } catch {}
        });

        source.onerror = () => {
          store.streamState = "reconnecting";
          updateStreamState();
        };

        source.onopen = () => {
          store.streamState = "live";
          updateStreamState();
        };
      };

      const updateStreamState = () => {
        const badge = document.querySelector("#stream-state");
        if (!badge) return;
        badge.textContent = store.streamState;
        badge.classList.toggle("live", store.streamState === "live");
      };

      const loadOverview = async () => {
        const overview = await fetchJson("/api/state?workspace=" + encodeURIComponent(store.currentWorkspace || ""));
        store.overview = overview;
        store.currentWorkspace = overview.workspace;
        trackOverviewChanges(overview);
        ensureSelection();
      };

      const loadWorkspaces = async () => {
        const response = await fetchJson("/api/workspaces?workspace=" + encodeURIComponent(store.currentWorkspace || ""));
        store.workspaces = response.items || [];
      };

      const loadLoopDetail = async (loopId) => {
        if (!loopId) return null;
        const detail = await fetchJson(
          "/api/loop?id=" +
            encodeURIComponent(loopId) +
            "&workspace=" +
            encodeURIComponent(store.currentWorkspace || "")
        );
        store.loopDetails.set(store.currentWorkspace + "::" + loopId, detail);
        ensureIterationSelection();
        ensureFileSelection();
        return detail;
      };

      const loadCampaignDetail = async (campaignId) => {
        if (!campaignId) return null;
        const detail = await fetchJson(
          "/api/campaign?id=" +
            encodeURIComponent(campaignId) +
            "&workspace=" +
            encodeURIComponent(store.currentWorkspace || "")
        );
        store.campaignDetails.set(store.currentWorkspace + "::" + campaignId, detail);
        return detail;
      };

      const renderMissionSnapshot = () => {
        const overview = store.overview;
        if (!overview) return;
        const summary = overview.summary;
        const selected = getSelectedLoopDetail();
        const metaRows = [
          { key: "status", value: (summary.activeStatus || "idle").toUpperCase() },
          { key: "loop", value: summary.activeLoopId || "none" }
        ];

        if (selected?.updatedAt || summary.updatedAt || overview.generatedAt) {
          metaRows.push({ key: "updated", value: shortDateTime(selected?.updatedAt || summary.updatedAt || overview.generatedAt) });
        }

        document.querySelector("#mission-snapshot").innerHTML =
          '<div class="summary-copy">' +
          escapeHtml(summary.missionHeadline || "No active mission.") +
          "</div>" +
          '<div class="focus-stack" style="margin-top:12px;">' +
          metaRows
            .map(
              (row) =>
                '<div class="focus-line"><div class="focus-key">' +
                escapeHtml(row.key) +
                '</div><div class="focus-value">' +
                escapeHtml(row.value) +
                "</div></div>"
            )
            .join("") +
          "</div>";
        document.querySelector("#snapshot-updated").textContent = shortDateTime(summary.updatedAt || overview.generatedAt);
      };

      const renderMissionGrid = () => {
        const overview = store.overview;
        if (!overview) return;
        const summary = overview.summary;
        const detail = getSelectedLoopDetail();
        const iteration = getSelectedIteration();
        const signalRows = [
          { key: "loop", value: detail?.id || summary.activeLoopId || "none" },
          { key: "state", value: (iterationStatusLabel(iteration) || summary.activeStatus || "idle").toUpperCase(), live: true },
          { key: "iteration", value: iteration?.id || "none" },
          {
            key: "updated",
            value: shortTime(detail?.updatedAt || summary.updatedAt || overview.generatedAt)
          }
        ];

        document.querySelector("#mission-grid").innerHTML =
          '<div class="signal-strip">' +
          signalRows
            .map(
              (row) =>
                '<div class="signal-row"><span class="signal-key">' +
                escapeHtml(row.key) +
                '</span><span class="signal-value' +
                (row.emphasis ? " emphasis" : "") +
                (row.live ? " live" : "") +
                '">' +
                escapeHtml(row.value) +
                "</span></div>"
            )
            .join("") +
          "</div>";
      };

      const renderWorkspaceStrip = () => {
        const workspaces = filteredWorkspaces();
        const target = document.querySelector("#workspace-strip");
        if (!workspaces.length) {
          target.innerHTML = '<div class="empty">No other workspaces with Ralph state were discovered nearby.</div>';
          return;
        }

        target.innerHTML = workspaces
          .slice(0, 5)
          .map(
            (workspace) =>
              '<button class="workspace-card' +
              (workspace.path === store.currentWorkspace ? " active" : "") +
              '" data-action="switch-workspace" data-workspace="' +
              escapeHtml(workspace.path) +
              '">' +
              '<div class="workspace-head">' +
              '<div class="workspace-name">' +
              escapeHtml(workspace.name) +
              "</div>" +
              '<div class="tiny">' +
              escapeHtml(workspace.status) +
              "</div>" +
              "</div>" +
              '<div class="workspace-meta">' +
              escapeHtml(workspace.missionHeadline) +
              "</div>" +
              "</button>"
          )
          .join("");
      };

      const renderLoopList = () => {
        const loops = filteredLoops();
        document.querySelector("#loop-explorer-count").textContent = compactCount(loops.length, "loop", "loops");
        const target = document.querySelector("#loop-list");
        if (!loops.length) {
          target.innerHTML = '<div class="empty">No loop matches this filter.</div>';
          return;
        }

        target.innerHTML = loops
          .slice(0, 10)
          .map((loop) => {
            const latest = loop.latestIteration;
            const subtitle = latest?.isInFlight
              ? latest.id + " · in-flight"
              : latest?.id
                ? latest.id + " · " + shortDateTime(loop.updatedAt)
                : shortDateTime(loop.updatedAt);
            return (
              '<button class="loop-card' +
              (loop.id === store.selectedLoopId ? " active" : "") +
              '" data-action="select-loop" data-loop-id="' +
              escapeHtml(loop.id) +
              '">' +
              '<div class="loop-head">' +
              '<div class="loop-name">' +
              escapeHtml(loop.id) +
              "</div>" +
              '<div class="tiny">' +
              escapeHtml(loop.status) +
              "</div>" +
              "</div>" +
              '<div class="loop-meta">' +
              escapeHtml(subtitle) +
              "</div>" +
              "</button>"
            );
          })
          .join("");
      };

      const renderBoundaryList = () => {
        const boundaries = store.overview?.workspaceBoundaries;
        document.querySelector("#boundary-counter").textContent =
          boundaries && boundaries.count != null ? compactCount(boundaries.count, "boundary", "boundaries") : "no boundary file";
        const target = document.querySelector("#boundary-list");
        if (!boundaries || !boundaries.items.length) {
          target.innerHTML = '<div class="empty">No explicit Current Boundaries section was found.</div>';
          return;
        }
        target.innerHTML =
          boundaries.items
            .map((item) => '<div class="loop-card active" style="cursor:default;">' + escapeHtml(item) + "</div>")
            .join("") +
          (boundaries.note ? '<div class="tiny">' + escapeHtml(boundaries.note) + "</div>" : "");
      };

      const renderInspector = () => {
        const detail = getSelectedLoopDetail();
        const iteration = getSelectedIteration();
        document.querySelector("#selected-loop-meta").textContent = detail ? detail.status : "idle";
        document.querySelector("#selected-loop-headline").textContent = detail?.id || "No loop selected.";
        document.querySelector("#selected-loop-badges").innerHTML = detail
          ? '<div class="focus-stack">' +
            [
              { key: "iteration", value: String(detail.iteration) + " / " + (detail.maxIterations === "0" ? "∞" : detail.maxIterations) },
              { key: "model", value: detail.model || "default" },
              { key: "updated", value: shortDateTime(detail.updatedAt) }
            ]
              .map(
                (row) =>
                  '<div class="focus-line"><div class="focus-key">' +
                  escapeHtml(row.key) +
                  '</div><div class="focus-value soft">' +
                  escapeHtml(row.value) +
                  "</div></div>"
              )
              .join("") +
            "</div>"
          : "";

        const strip = document.querySelector("#iteration-strip");
        if (!detail || !detail.iterations.length) {
          strip.innerHTML = '<div class="empty">No iterations captured yet.</div>';
        } else {
          strip.innerHTML = detail.iterations
            .map(
              (item) =>
                '<button class="iteration-chip' +
                (item.id === store.selectedIterationId ? " active" : "") +
                '" data-action="select-iteration" data-iteration-id="' +
                escapeHtml(item.id) +
                '">' +
                "<strong>" +
                escapeHtml(item.id) +
                "</strong>" +
                "<span>" +
                escapeHtml(item.isInFlight ? "in flight" : shortDateTime(item.endedAt || item.startedAt)) +
                "</span>" +
                "</button>"
            )
            .join("");
        }

        const availableArtifacts = [
          { id: "closeout", label: "closeout", enabled: Boolean(iteration?.finalMessage) },
          { id: "stderr", label: "live stderr", enabled: Boolean(iteration?.stderrTail) },
          { id: "session", label: "session", enabled: Boolean(iteration?.sessionTail) },
          { id: "files", label: "files", enabled: Boolean(iteration?.fileRefs?.length) },
          { id: "prompt", label: "prompt", enabled: Boolean(iteration?.promptPreview) },
          { id: "task", label: "task copy", enabled: Boolean(iteration?.taskPreview) }
        ].filter((artifact) => artifact.enabled);

        document.querySelector("#artifact-switch").innerHTML = availableArtifacts
          .map(
            (artifact) =>
              '<button class="artifact-toggle' +
              (currentArtifact(iteration) === artifact.id ? " active" : "") +
              '" data-action="select-artifact" data-artifact="' +
              escapeHtml(artifact.id) +
              '">' +
              escapeHtml(artifact.label) +
              "</button>"
          )
          .join("");

        const artifact = currentArtifact(iteration);
        const body = document.querySelector("#artifact-body");
        const title = document.querySelector("#artifact-title");
        if (!iteration) {
          title.textContent = "Artifact";
          body.innerHTML = '<div class="empty">Pick a loop to inspect iteration artifacts.</div>';
          return;
        }

        if (artifact === "closeout") {
          title.textContent = "Closeout";
          const sections = splitCloseoutSections(iteration.finalMessage);
          body.innerHTML = sections.length
            ? '<div class="closeout-stack">' +
              sections
                .map(
                  (section) =>
                    '<section class="closeout-box"><h4>' +
                    escapeHtml(section.title) +
                    "</h4><ul>" +
                    section.lines.map((line) => "<li>" + escapeHtml(line) + "</li>").join("") +
                    "</ul></section>"
                )
                .join("") +
              "</div>"
            : "<pre>" + escapeHtml(iteration.finalMessage || "(no closeout)") + "</pre>";
          return;
        }

        if (artifact === "stderr") {
          title.textContent = "Live stderr";
          body.innerHTML = "<pre>" + escapeHtml(iteration.stderrTail || "(no stderr tail)") + "</pre>";
          return;
        }

        if (artifact === "session") {
          title.textContent = "Session output";
          body.innerHTML = "<pre>" + escapeHtml(iteration.sessionTail || "(no session output)") + "</pre>";
          return;
        }

        if (artifact === "files") {
          title.textContent = "Iteration file refs";
          body.innerHTML =
            '<div class="files-list">' +
            (iteration.fileRefs || [])
              .map(
                (file) =>
                  '<div class="file-row active" style="cursor:default;">' +
                  '<div><div class="path">' +
                  escapeHtml(file.relativePath) +
                  '</div><div class="tiny">' +
                  escapeHtml(file.sources.join(", ")) +
                  "</div></div>" +
                  '<div class="category">' +
                  escapeHtml(file.category) +
                  " · " +
                  escapeHtml(String(file.mentions)) +
                  "</div></div>"
              )
              .join("") +
            "</div>";
          return;
        }

        if (artifact === "prompt") {
          title.textContent = "Prompt snapshot";
          body.innerHTML = "<pre>" + escapeHtml(iteration.promptPreview || "(no prompt snapshot)") + "</pre>";
          return;
        }

        title.textContent = "Task copy";
        body.innerHTML = "<pre>" + escapeHtml(iteration.taskPreview || "(no task copy)") + "</pre>";
      };

      const buildConsoleLines = () => {
        const detail = getSelectedLoopDetail();
        const iteration = getSelectedIteration();
        const lines = [];

        if (iteration?.stderrTail) {
          iteration.stderrTail.split("\n").slice(-80).forEach((line) => {
            lines.push({
              time: shortTime(detail?.updatedAt || store.overview?.generatedAt),
              body: line,
              level: line.startsWith("**Done**")
                ? "done"
                : line.startsWith("**Open**")
                  ? "open"
                  : line.startsWith("**Next**")
                    ? "next"
                    : /error|failed|warning/i.test(line)
                      ? "warning"
                      : ""
            });
          });
        }

        if (!lines.length && store.overview?.activityFeed?.length) {
          store.overview.activityFeed.slice(0, 24).forEach((item) => {
            lines.push({
              time: shortTime(item.timestamp),
              body: "[" + item.kind + "] " + item.title + " — " + item.summary,
              level: item.active ? "next" : ""
            });
          });
        }

        return lines;
      };

      const renderStreamView = () => {
        const detail = getSelectedLoopDetail();
        const iteration = getSelectedIteration();
        const chipbox = document.querySelector("#stream-chipbox");
        chipbox.innerHTML = detail
          ? '<div class="telemetry-inline">' +
            [
              { key: "workspace", value: store.currentWorkspace },
              { key: "loop", value: detail.id },
              { key: "iteration", value: iteration?.id || "none" },
              { key: "state", value: iterationStatusLabel(iteration).toUpperCase() }
            ]
              .map(
                (row) =>
                  '<div class="telemetry-stat"><span class="key">' +
                  escapeHtml(row.key) +
                  '</span><span class="value' +
                  (row.key === "state" ? " live" : "") +
                  '">' +
                  escapeHtml(row.value) +
                  "</span></div>"
              )
              .join("") +
            "</div>"
          : '<div class="telemetry-inline"><div class="telemetry-stat"><span class="key">workspace</span><span class="value">' +
            escapeHtml(store.currentWorkspace) +
            "</span></div></div>";

        document.querySelector("#stream-status-copy").textContent =
          detail?.taskHeadline || store.overview?.summary.missionHeadline || "Waiting for live loop data.";

        const consoleLines = buildConsoleLines();
        document.querySelector("#stream-console").innerHTML = consoleLines.length
          ? consoleLines
              .map(
                (line) =>
                  '<div class="console-line"><div class="console-time">' +
                  escapeHtml(line.time) +
                  '</div><div class="console-body ' +
                  escapeHtml(line.level) +
                  '">' +
                  escapeHtml(line.body || "") +
                  "</div></div>"
              )
              .join("")
          : '<div class="empty">No live stream lines yet.</div>';
      };

      const renderMissionView = () => {
        const detail = getSelectedLoopDetail();
        const iteration = getSelectedIteration();
        document.querySelector("#mission-blueprint").textContent = detail?.task || "No mission task loaded.";
        document.querySelector("#mission-handoff").textContent = detail?.handoff || detail?.lastMessage || "No handoff recorded yet.";

        const closeoutSections = splitCloseoutSections(iteration?.finalMessage || detail?.lastMessage || "");
        document.querySelector("#closeout-stack").innerHTML = closeoutSections.length
          ? closeoutSections
              .map(
                (section) =>
                  '<section class="closeout-box"><h4>' +
                  escapeHtml(section.title) +
                  "</h4><ul>" +
                  section.lines.map((line) => "<li>" + escapeHtml(line) + "</li>").join("") +
                  "</ul></section>"
              )
              .join("")
          : '<div class="empty">No closeout sections are available for the selected iteration.</div>';

        const feedItems = (store.overview?.activityFeed || []).filter((item) =>
          textMatchesFilter(item.title + " " + item.summary + " " + item.label)
        );
        document.querySelector("#activity-feed").innerHTML = feedItems.length
          ? feedItems
              .map(
                (item) =>
                  '<div class="loop-card' +
                  (item.active ? " active" : "") +
                  '" style="cursor:default;"><div class="feed-head"><div class="feed-title">' +
                  escapeHtml(item.title) +
                  "</div><div class=\"tiny\">" +
                  escapeHtml(shortDateTime(item.timestamp)) +
                  '</div></div><div class="feed-copy">' +
                  escapeHtml(item.summary) +
                  "</div></div>"
              )
              .join("")
          : '<div class="empty">No activity items match this filter.</div>';
      };

      const renderFilesView = () => {
        const files = filteredFiles();
        const selected = files.find((file) => file.absPath === store.selectedFilePath) || files[0] || null;
        if (selected) {
          store.selectedFilePath = selected.absPath;
        }

        document.querySelector("#files-list").innerHTML = files.length
          ? files
              .map(
                (file) =>
                  '<button class="file-row' +
                  (file.absPath === store.selectedFilePath ? " active" : "") +
                  '" data-action="select-file" data-file-path="' +
                  escapeHtml(file.absPath) +
                  '">' +
                  '<div><div class="path">' +
                  escapeHtml(file.relativePath) +
                  '</div><div class="tiny">' +
                  escapeHtml(file.sources.join(", ")) +
                  '</div></div><div class="category">' +
                  escapeHtml(file.category) +
                  " · " +
                  escapeHtml(String(file.mentions)) +
                  "</div></button>"
              )
              .join("")
          : '<div class="empty">No touched files match this filter.</div>';

        document.querySelector("#file-detail").innerHTML = selected
          ? '<div class="closeout-stack"><section class="closeout-box"><h4>Path</h4><pre>' +
            escapeHtml(selected.absPath) +
            '</pre></section><section class="closeout-box"><h4>Mentions</h4><pre>' +
            escapeHtml(String(selected.mentions)) +
            '</pre></section><section class="closeout-box"><h4>Sources</h4><pre>' +
            escapeHtml(selected.sources.join("\n")) +
            "</pre></section></div>"
          : '<div class="empty">Pick a file to inspect where it was referenced.</div>';
      };

      const renderWorkspacesView = () => {
        const items = filteredWorkspaces();
        document.querySelector("#workspace-grid").innerHTML = items.length
          ? items
              .map(
                (workspace) =>
                  '<button class="workspace-card' +
                  (workspace.path === store.currentWorkspace ? " active" : "") +
                  '" data-action="switch-workspace" data-workspace="' +
                  escapeHtml(workspace.path) +
                  '">' +
                  '<div class="workspace-head"><div class="workspace-name">' +
                  escapeHtml(workspace.name) +
                  '</div><div class="tiny">' +
                  escapeHtml(workspace.status) +
                  '</div></div><div class="workspace-meta">' +
                  escapeHtml(workspace.path) +
                  '</div><div class="workspace-meta">' +
                  escapeHtml(workspace.missionHeadline) +
                  '</div><div class="status-badges">' +
                  makeBadge("loops", workspace.loopCount) +
                  makeBadge("boundaries", workspace.boundaryCount == null ? "n/a" : workspace.boundaryCount, "warning") +
                  "</div></button>"
              )
              .join("")
          : '<div class="empty">No nearby Ralph workspaces match this filter.</div>';
      };

      const renderNotificationsView = () => {
        const notifications = store.notifications.filter((item) =>
          textMatchesFilter(item.title + " " + item.message)
        );

        document.querySelector("#notifications-log").innerHTML = notifications.length
          ? notifications
              .map(
                (item) =>
                  '<div class="loop-card active" style="cursor:default;"><div class="notification-head"><div class="notification-title">' +
                  escapeHtml(item.title) +
                  "</div><div class=\"tiny\">" +
                  escapeHtml(shortDateTime(item.timestamp)) +
                  '</div></div><div class="notification-copy">' +
                  escapeHtml(item.message) +
                  "</div></div>"
              )
              .join("")
          : '<div class="empty">No notifications yet. Mission updates will appear here.</div>';

        const detail = getSelectedLoopDetail();
        document.querySelector("#system-pulse").innerHTML = [
          { label: "active workspace", value: store.currentWorkspace },
          { label: "active loop", value: store.overview?.summary.activeLoopId || "none" },
          { label: "pid", value: detail?.pid || "n/a" },
          { label: "sandbox", value: detail?.sandboxMode || "n/a" },
          { label: "approval", value: detail?.approvalPolicy || "n/a" }
        ]
          .map(
            (item) =>
              '<div class="loop-card active" style="cursor:default;"><div class="notification-head"><div class="notification-title">' +
              escapeHtml(item.label) +
              '</div></div><div class="notification-copy mono">' +
              escapeHtml(item.value) +
              "</div></div>"
          )
          .join("");
      };

      const renderViewPanels = () => {
        const titleMap = {
          stream: ["Live Execution", "mission telemetry"],
          mission: ["Mission Context", "briefing, handoff, closeout"],
          files: ["Files Changed", "touched paths and references"],
          workspaces: ["Workspace Grid", "multi-workspace overview"],
          notifications: ["Notifications", "alerts and system pulse"]
        };

        for (const panel of document.querySelectorAll("[data-view-panel]")) {
          panel.classList.toggle("active", panel.getAttribute("data-view-panel") === store.selectedView);
        }

        for (const tab of document.querySelectorAll(".tab-button")) {
          tab.classList.toggle("active", tab.getAttribute("data-view") === store.selectedView);
        }

        document.querySelector("#view-title").textContent = titleMap[store.selectedView][0];
        document.querySelector("#view-meta").textContent = titleMap[store.selectedView][1];
      };

      const buildComposerCommand = () => {
        const workspace = store.currentWorkspace || "/path/to/workspace";
        const mode = document.querySelector("#composer-mode")?.value || "loop";
        const promise = (document.querySelector("#composer-promise")?.value || "SHIPIT").trim() || "SHIPIT";
        const maxIterations = (document.querySelector("#composer-max-iterations")?.value || "0").trim() || "0";
        const verify = (document.querySelector("#composer-verify")?.value || "npm run verify").trim() || "npm run verify";
        const text = (document.querySelector("#composer-text")?.value || "").trim() || "Describe the mission here.";

        if (mode === "campaign") {
          return [
            "bash ~/plugins/ralph/scripts/ralph-loop.sh campaign \\",
            "  --cwd " + workspace + " \\",
            "  --verify-cmd '" + verify.replaceAll("'", "'\"'\"'") + "' \\",
            "  --promise-prefix " + promise + " \\",
            "  --loop-max-iterations " + maxIterations + " \\",
            "  --goal-file /tmp/ralph-goal.md"
          ].join("\n");
        }

        return [
          "bash ~/plugins/ralph/scripts/ralph-loop.sh start \\",
          "  --cwd " + workspace + " \\",
          "  --completion-promise " + promise + " \\",
          "  --max-iterations " + maxIterations + " \\",
          '  "' + text.replaceAll('"', '\\"') + '"'
        ].join("\n");
      };

      const renderComposer = () => {
        document.querySelector("#composer-preview").textContent = buildComposerCommand();
      };

      const renderWindowChrome = () => {
        const workspaceName = store.currentWorkspace ? store.currentWorkspace.split("/").filter(Boolean).slice(-1)[0] : "workspace";
        document.querySelector(".window")?.setAttribute("data-view", store.selectedView);
        document.querySelector("#window-title").textContent = "ralph-mission-control — " + workspaceName;
        document.querySelector("#window-subtitle").textContent = (store.overview?.summary.activeLoopId || "no-active-loop") + " · " + store.selectedView;
      };

      const render = () => {
        if (!store.overview) return;
        renderWindowChrome();
        renderMissionSnapshot();
        renderMissionGrid();
        renderWorkspaceStrip();
        renderLoopList();
        renderBoundaryList();
        renderInspector();
        renderStreamView();
        renderMissionView();
        renderFilesView();
        renderWorkspacesView();
        renderNotificationsView();
        renderViewPanels();
        renderComposer();
      };

      const refreshEverything = async () => {
        await loadOverview();
        await Promise.all([loadWorkspaces(), loadLoopDetail(store.selectedLoopId), loadCampaignDetail(store.selectedCampaignId)]);
        ensureIterationSelection();
        ensureFileSelection();
        render();
      };

      document.addEventListener("click", async (event) => {
        const target = event.target.closest("[data-action], [data-view]");
        if (!target) return;

        const view = target.getAttribute("data-view");
        if (view) {
          store.selectedView = view;
          render();
          return;
        }

        const action = target.getAttribute("data-action");
        if (action === "select-loop") {
          const loopId = target.getAttribute("data-loop-id");
          if (!loopId) return;
          store.selectedLoopId = loopId;
          store.pinnedLoopSelection = true;
          store.pinnedIterationSelection = false;
          store.selectedArtifact = "auto";
          await loadLoopDetail(loopId);
          render();
          return;
        }

        if (action === "select-iteration") {
          const iterationId = target.getAttribute("data-iteration-id");
          if (!iterationId) return;
          store.selectedIterationId = iterationId;
          store.pinnedIterationSelection = true;
          store.selectedArtifact = "auto";
          render();
          return;
        }

        if (action === "select-artifact") {
          const artifact = target.getAttribute("data-artifact");
          if (!artifact) return;
          store.selectedArtifact = artifact;
          render();
          return;
        }

        if (action === "select-file") {
          const filePath = target.getAttribute("data-file-path");
          if (!filePath) return;
          store.selectedFilePath = filePath;
          render();
          return;
        }

        if (action === "switch-workspace") {
          const workspace = target.getAttribute("data-workspace");
          if (!workspace || workspace === store.currentWorkspace) return;
          store.currentWorkspace = workspace;
          store.selectedLoopId = "";
          store.selectedCampaignId = "";
          store.selectedIterationId = "";
          store.selectedFilePath = "";
          store.selectedArtifact = "auto";
          store.pinnedLoopSelection = false;
          store.pinnedCampaignSelection = false;
          store.pinnedIterationSelection = false;
          await refreshEverything();
          openEventStream();
        }
      });

      document.querySelector("#global-filter").addEventListener("input", (event) => {
        store.filterText = normalizeText(event.target.value);
        render();
      });

      document.querySelector("#notification-permission").addEventListener("click", async () => {
        if (!("Notification" in window)) {
          notify("Notifications unavailable", "This browser does not expose the Notification API.");
          return;
        }
        if (Notification.permission === "granted") {
          notify("Notifications already enabled", "Browser notifications are already enabled for this page.");
          return;
        }
        const result = await Notification.requestPermission();
        notify("Notification permission", "Permission state: " + result);
      });

      document.querySelector("#copy-command").addEventListener("click", async () => {
        const value = buildComposerCommand();
        try {
          await navigator.clipboard.writeText(value);
          notify("Command copied", "Mission launch command copied to clipboard.");
        } catch {
          notify("Copy failed", "Clipboard write failed in this browser tab.", "warning");
        }
      });

      document.querySelector("#copy-prompt").addEventListener("click", async () => {
        const value = (document.querySelector("#composer-text")?.value || "").trim();
        try {
          await navigator.clipboard.writeText(value);
          notify("Prompt copied", "Mission draft copied to clipboard.");
        } catch {
          notify("Copy failed", "Clipboard write failed in this browser tab.", "warning");
        }
      });

      document.querySelector("#composer-form").addEventListener("input", () => {
        renderComposer();
      });

      async function bootstrap() {
        store.currentWorkspace = "";
        await refreshEverything();
        openEventStream();
      }

      bootstrap().catch((error) => {
        document.body.innerHTML =
          '<div class="app-shell"><div class="window" style="display:flex;align-items:center;justify-content:center;"><div class="empty" style="max-width:560px;">' +
          escapeHtml(error.message) +
          "</div></div></div>";
      });
    </script>
  </body>
</html>`;
}
