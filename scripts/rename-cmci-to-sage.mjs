import fs from "node:fs/promises";
import path from "node:path";

const targetRoot = process.argv[2];

if (!targetRoot) {
  console.error("Usage: node scripts/rename-cmci-to-sage.mjs <target-root>");
  process.exit(1);
}

const textExtensions = new Set([
  ".js",
  ".json",
  ".md",
  ".txt",
  ".csv",
  ".yml",
  ".yaml"
]);

const skipNames = new Set(["node_modules", ".git", ".ralph", "output", "tmp"]);

const renamePathSegments = new Map([
  ["docs/cmci-prd.md", "docs/sage-prd.md"],
  ["docs/cmci-technical-design.md", "docs/sage-technical-design.md"]
]);

const orderedReplacements = [
  ["Context-Maximized Creative Intelligence", "Semantic Agentic Generation Engine"],
  ["runCmciPipeline", "runSagePipeline"],
  ["CMCI_STATE_DB_PATH", "SAGE_STATE_DB_PATH"],
  ["CMCI_OBJECT_STORE_ROOT", "SAGE_OBJECT_STORE_ROOT"],
  ["CMCI_PROVIDER_CHAIN", "SAGE_PROVIDER_CHAIN"],
  ["CMCI_EMBEDDINGS_PROVIDER_CHAIN", "SAGE_EMBEDDINGS_PROVIDER_CHAIN"],
  ["CMCI_PROVIDER_FAILOVER_PHASE_AWARE", "SAGE_PROVIDER_FAILOVER_PHASE_AWARE"],
  ["CMCI_PROVIDER_FAILOVER_LATENCY_AWARE", "SAGE_PROVIDER_FAILOVER_LATENCY_AWARE"],
  ["CMCI_PROVIDER_FAILOVER_LATENCY_STEP_MS", "SAGE_PROVIDER_FAILOVER_LATENCY_STEP_MS"],
  ["CMCI_PROVIDER_FAILOVER_LATENCY_EMA_ALPHA", "SAGE_PROVIDER_FAILOVER_LATENCY_EMA_ALPHA"],
  ["CMCI_PROVIDER_FAILOVER_COOLDOWN_MS", "SAGE_PROVIDER_FAILOVER_COOLDOWN_MS"],
  ["CMCI_OPENAI_DISTILL_MODEL", "SAGE_OPENAI_DISTILL_MODEL"],
  ["CMCI_OPENAI_META_MODEL", "SAGE_OPENAI_META_MODEL"],
  ["CMCI_OPENAI_QA_MODEL", "SAGE_OPENAI_QA_MODEL"],
  ["CMCI_OPENAI_EMBEDDINGS_MODEL", "SAGE_OPENAI_EMBEDDINGS_MODEL"],
  ["CMCI_OPENAI_EMBEDDINGS_DIMENSIONS", "SAGE_OPENAI_EMBEDDINGS_DIMENSIONS"],
  ["CMCI_OPENAI_EMBEDDINGS_BATCH_SIZE", "SAGE_OPENAI_EMBEDDINGS_BATCH_SIZE"],
  ["CMCI_OPENAI_MAX_RETRIES", "SAGE_OPENAI_MAX_RETRIES"],
  ["CMCI_OPENAI_RETRY_BASE_MS", "SAGE_OPENAI_RETRY_BASE_MS"],
  ["CMCI_OPENAI_RETRY_MAX_MS", "SAGE_OPENAI_RETRY_MAX_MS"],
  ["CMCI_OPENAI_REQUEST_TIMEOUT_MS", "SAGE_OPENAI_REQUEST_TIMEOUT_MS"],
  ["CMCI_OPENAI_PREFLIGHT_TOKENS", "SAGE_OPENAI_PREFLIGHT_TOKENS"],
  ["CMCI_ANTHROPIC_DISTILL_MODEL", "SAGE_ANTHROPIC_DISTILL_MODEL"],
  ["CMCI_ANTHROPIC_META_MODEL", "SAGE_ANTHROPIC_META_MODEL"],
  ["CMCI_ANTHROPIC_QA_MODEL", "SAGE_ANTHROPIC_QA_MODEL"],
  ["CMCI_TOKENIZER_MODEL", "SAGE_TOKENIZER_MODEL"],
  ["CMCI_SECTION_INPUT_TARGET_TOKENS", "SAGE_SECTION_INPUT_TARGET_TOKENS"],
  ["CMCI_SECTION_MIN_EVIDENCE_TOKENS", "SAGE_SECTION_MIN_EVIDENCE_TOKENS"],
  ["CMCI_SECTION_MAX_EVIDENCE_TOKENS", "SAGE_SECTION_MAX_EVIDENCE_TOKENS"],
  ["CMCI_MOCK_LLM_DELAY_MS", "SAGE_MOCK_LLM_DELAY_MS"],
  ["CMCI_MOCK_EMBEDDINGS_DELAY_MS", "SAGE_MOCK_EMBEDDINGS_DELAY_MS"],
  ["CMCI_COOPERATIVE_YIELD_INTERVAL", "SAGE_COOPERATIVE_YIELD_INTERVAL"],
  ["CMCI_LAYER1_CONCURRENCY", "SAGE_LAYER1_CONCURRENCY"],
  ["CMCI_WORKFLOW_LEASE_RENEW_INTERVAL_MS", "SAGE_WORKFLOW_LEASE_RENEW_INTERVAL_MS"],
  ["CMCI_PANEL_DELIVERY_TRANSPORT", "SAGE_PANEL_DELIVERY_TRANSPORT"],
  ["CMCI_PANEL_SMTP_HOST", "SAGE_PANEL_SMTP_HOST"],
  ["CMCI_PANEL_SMTP_PORT", "SAGE_PANEL_SMTP_PORT"],
  ["CMCI_PANEL_SMTP_FROM", "SAGE_PANEL_SMTP_FROM"],
  ["CMCI_PROVIDER", "SAGE_PROVIDER"],
  ["CMCI_EMBEDDINGS_PROVIDER", "SAGE_EMBEDDINGS_PROVIDER"],
  ["CMCI_ARTIFACT_BACKEND", "SAGE_ARTIFACT_BACKEND"],
  ["CMCI_VECTOR_BACKEND", "SAGE_VECTOR_BACKEND"],
  ["CMCI_", "SAGE_"],
  ["x-cmci-api-key", "x-sage-api-key"],
  ["x-cmci-panel-token", "x-sage-panel-token"],
  ["x-cmci-panel-invite-token", "x-sage-panel-invite-token"],
  ["cmci_eval.", "sage_eval."],
  ["cmci_inv.", "sage_inv."],
  ["cmci.", "sage."],
  ["cmci_eval", "sage_eval"],
  ["cmci_inv", "sage_inv"],
  ["cmci-csp", "sage-csp"],
  ["cmci-", "sage-"],
  ["cmci_", "sage_"],
  ["CMCI", "SAGE"],
  ["Cmci", "Sage"],
  ["cmci", "sage"]
];

async function walk(dir, out = []) {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    if (skipNames.has(entry.name)) {
      continue;
    }
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      await walk(fullPath, out);
    } else {
      out.push(fullPath);
    }
  }
  return out;
}

function replaceAll(content) {
  let next = content;
  for (const [from, to] of orderedReplacements) {
    next = next.split(from).join(to);
  }
  return next;
}

function isTextFile(filePath) {
  const base = path.basename(filePath);
  if (base === "package-lock.json" || base === "package.json" || base === "LICENSE" || base === "README.md") {
    return true;
  }
  return textExtensions.has(path.extname(filePath));
}

async function renameMappedFiles(root) {
  for (const [fromRel, toRel] of renamePathSegments.entries()) {
    const from = path.join(root, fromRel);
    const to = path.join(root, toRel);
    try {
      await fs.access(from);
    } catch {
      continue;
    }
    await fs.mkdir(path.dirname(to), { recursive: true });
    await fs.rename(from, to);
  }
}

async function main() {
  await renameMappedFiles(targetRoot);

  const files = await walk(targetRoot);
  let changedFiles = 0;

  for (const filePath of files) {
    if (!isTextFile(filePath)) {
      continue;
    }

    const original = await fs.readFile(filePath, "utf8");
    const updated = replaceAll(original);
    if (updated === original) {
      continue;
    }
    await fs.writeFile(filePath, updated, "utf8");
    changedFiles += 1;
  }

  console.log(`Updated ${changedFiles} file(s) in ${targetRoot}`);
}

await main();
