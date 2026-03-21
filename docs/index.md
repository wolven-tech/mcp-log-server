---
layout: landing
title: Home
---

<section class="hero">
  <div class="container">
    <h1>MCP Log Server</h1>
    <p class="tagline">Token-efficient log analysis tools for LLMs via the Model Context Protocol. Built in Elixir. One dependency.</p>

    <div class="badge-group">
      <span class="badge purple">MCP Compatible</span>
      <span class="badge green">9 Tools</span>
      <span class="badge blue">JSON + Plain Text</span>
      <span class="badge amber">~50% Token Savings</span>
      <span class="badge">Elixir 1.17+</span>
      <span class="badge">Docker + Source</span>
    </div>

    <div class="install-block">
      <code><span class="dim">$</span> docker pull ghcr.io/wolven-tech/mcp-log-server:latest</code>
    </div>

    <div class="cta-group">
      <a href="getting-started/QUICK_START.html" class="btn btn-primary">Get Started</a>
      <a href="https://github.com/wolven-tech/mcp-log-server" class="btn btn-secondary">View on GitHub</a>
    </div>
  </div>
</section>

<section>
  <div class="container">
    <h2>The Problem</h2>
    <p class="section-sub">LLMs waste tokens parsing raw log files. A 10 MB dump burns thousands of tokens before reasoning even starts.</p>

    <div class="toon-demo">
      <div>
        <div class="label">Before: Raw JSON (~1200 tokens)</div>
        <div class="code-block">
<span class="comment">// Paste 500 lines into context...</span>
{"level":"info","msg":"Server started","ts":"..."}
{"level":"info","msg":"Connected to DB","ts":"..."}
{"level":"info","msg":"Health check OK","ts":"..."}
<span class="comment">... 497 more lines of noise ...</span>
        </div>
      </div>
      <div>
        <div class="label">After: TOON format (~600 tokens)</div>
        <div class="code-block">
<span class="keyword">[severity|timestamp|message|line]</span>
<span class="string">ERROR</span>|14:02:15|Connection refused|42
<span class="string">ERROR</span>|14:02:20|Max retries exceeded|87
<span class="string">WARN</span>|14:02:25|Pool exhausted|91
        </div>
      </div>
      <div class="savings">
        <strong>~50% fewer tokens</strong> &mdash; TOON's pipe-delimited format compounds over 20+ tool calls per session
      </div>
    </div>
  </div>
</section>

<section id="tools">
  <div class="container">
    <h2>9 Tools</h2>
    <p class="section-sub">Organized by workflow stage: discover, analyze, correlate.</p>

    <table class="tools-table">
      <thead>
        <tr><th>Tool</th><th>Description</th></tr>
      </thead>
      <tbody>
        <tr><td colspan="2" class="tool-category">Discovery</td></tr>
        <tr><td>list_logs</td><td>List available log files with size and modification time</td></tr>
        <tr><td>log_stats</td><td>Line count, error/warn/fatal counts, file size &mdash; quick health check</td></tr>
        <tr><td>time_range</td><td>Earliest and latest timestamps with human-readable span</td></tr>
        <tr><td colspan="2" class="tool-category">Analysis</td></tr>
        <tr><td>all_errors</td><td>Aggregate errors across ALL files &mdash; best first call</td></tr>
        <tr><td>get_errors</td><td>Errors with severity filtering, exclude patterns, and time range</td></tr>
        <tr><td>search_logs</td><td>Regex search with context lines, JSON field targeting, time range</td></tr>
        <tr><td>tail_log</td><td>Last N lines with optional <code>since</code> filtering</td></tr>
        <tr><td colspan="2" class="tool-category">Correlation</td></tr>
        <tr><td>correlate</td><td>Trace a request/session across ALL files &mdash; unified timeline</td></tr>
        <tr><td>trace_ids</td><td>Discover unique session/request/trace IDs with counts</td></tr>
      </tbody>
    </table>

    <p style="text-align: center; margin-top: 24px;">
      <a href="reference/TOOLS.html" class="btn btn-secondary">Full Tool Reference &rarr;</a>
    </p>
  </div>
</section>

<section id="workflow">
  <div class="container">
    <h2>Recommended Workflow</h2>
    <p class="section-sub">From triage to root cause in 5 steps.</p>

    <div class="workflow">
      <div class="workflow-step">
        <div class="step-num">1</div>
        <h4>all_errors</h4>
        <p>What's broken?</p>
      </div>
      <div class="workflow-arrow">&rarr;</div>
      <div class="workflow-step">
        <div class="step-num">2</div>
        <h4>log_stats</h4>
        <p>How bad is it?</p>
      </div>
      <div class="workflow-arrow">&rarr;</div>
      <div class="workflow-step">
        <div class="step-num">3</div>
        <h4>get_errors</h4>
        <p>Filter by severity + time</p>
      </div>
      <div class="workflow-arrow">&rarr;</div>
      <div class="workflow-step">
        <div class="step-num">4</div>
        <h4>search_logs</h4>
        <p>Context around errors</p>
      </div>
      <div class="workflow-arrow">&rarr;</div>
      <div class="workflow-step">
        <div class="step-num">5</div>
        <h4>correlate</h4>
        <p>Cross-service trace</p>
      </div>
    </div>
  </div>
</section>

<section id="features">
  <div class="container">
    <h2>Key Features</h2>
    <p class="section-sub">Built for real-world debugging workflows.</p>

    <div class="grid">
      <div class="card">
        <h3><span class="card-icon purple">{ }</span> JSON Auto-Detection</h3>
        <p>Drop in JSON log files from Pino, structlog, GCP Cloud Logging, or any framework. The server auto-detects the format, extracts severity from standard fields, and maps numeric Pino levels. Zero false positives on error detection.</p>
      </div>
      <div class="card">
        <h3><span class="card-icon green">&#9201;</span> Time-Based Filtering</h3>
        <p>Every analysis tool supports <code>since</code> and <code>until</code> &mdash; absolute ISO 8601 or relative shorthands like <code>"30m"</code>, <code>"2h"</code>, <code>"1d"</code>. Stop scanning 24 hours when the incident was 30 minutes.</p>
      </div>
      <div class="card">
        <h3><span class="card-icon blue">&#8644;</span> Cross-Service Correlation</h3>
        <p>Trace a request ID, session ID, or trace ID across every log file in one call. Returns a unified timeline sorted by timestamp, showing the request's path through all services.</p>
      </div>
      <div class="card">
        <h3><span class="card-icon amber">&#9881;</span> Configurable Patterns</h3>
        <p>Severity level filtering (<code>fatal</code> &gt; <code>error</code> &gt; <code>warn</code> &gt; <code>info</code>), exclude patterns for known noise, and custom error patterns via environment variables. All compiled once at startup.</p>
      </div>
      <div class="card">
        <h3><span class="card-icon red">&#9731;</span> Token Efficiency</h3>
        <p>TOON format delivers ~50% token savings over JSON for tabular data. For sessions with 20+ tool calls, this compounds into thousands of saved tokens and faster responses.</p>
      </div>
      <div class="card">
        <h3><span class="card-icon purple">&#9875;</span> Clean Architecture</h3>
        <p>Tool behaviour pattern &mdash; add a new tool by creating one module. 7 focused domain modules. Runtime-configurable patterns via <code>persistent_term</code>. One dependency (Jason). OTP supervision for crash resilience.</p>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="container">
    <h2>Quick Start</h2>
    <p class="section-sub">Running in under 2 minutes.</p>

    <div class="grid" style="grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));">
      <div class="card">
        <h3>1. Pull the image</h3>
        <div class="code-block" style="margin-top: 12px;">
<span class="dim">$</span> docker pull ghcr.io/wolven-tech/mcp-log-server:latest
        </div>
      </div>
      <div class="card">
        <h3>2. Add to .mcp.json</h3>
        <div class="code-block" style="margin-top: 12px;">
{
  "<span class="string">mcpServers</span>": {
    "<span class="string">log-server</span>": {
      "<span class="string">command</span>": "docker",
      "<span class="string">args</span>": ["run", "--rm", "-i",
        "-v", "./tmp/logs:/tmp/mcp-logs:ro",
        "ghcr.io/wolven-tech/mcp-log-server:latest"]
    }
  }
}
        </div>
      </div>
      <div class="card">
        <h3>3. Pipe your logs</h3>
        <div class="code-block" style="margin-top: 12px;">
<span class="comment"># All services to one file</span>
<span class="dim">$</span> turbo run dev 2>&amp;1 | tee ./tmp/logs/apps.log

<span class="comment"># Or per-service (better for correlate)</span>
<span class="dim">$</span> turbo run dev --filter=api 2>&amp;1 | tee ./tmp/logs/api.log
<span class="dim">$</span> turbo run dev --filter=web 2>&amp;1 | tee ./tmp/logs/web.log
        </div>
      </div>
    </div>

    <p style="text-align: center; margin-top: 32px;">
      <a href="getting-started/QUICK_START.html" class="btn btn-primary">Full Quick Start Guide &rarr;</a>
    </p>
  </div>
</section>

<section id="examples">
  <div class="container">
    <h2>Architecture</h2>
    <p class="section-sub">Layered, SOLID, extensible.</p>

    <div class="arch-diagram">
      <div class="arch-layer" style="background: rgba(88, 166, 255, 0.1); border-color: rgba(88, 166, 255, 0.3);">
        Transport (stdio) &mdash; JSON-RPC 2.0
      </div>
      <div class="arch-arrow">&darr;</div>
      <div class="arch-layer" style="background: rgba(139, 92, 246, 0.1); border-color: rgba(139, 92, 246, 0.3);">
        Server (method routing)
      </div>
      <div class="arch-arrow">&darr;</div>
      <div class="arch-layer" style="background: rgba(63, 185, 80, 0.1); border-color: rgba(63, 185, 80, 0.3);">
        Tools (behaviour + 9 self-contained modules)
      </div>
      <div class="arch-arrow">&darr;</div>
      <div class="arch-layer" style="background: rgba(210, 153, 34, 0.1); border-color: rgba(210, 153, 34, 0.3);">
        Domain (7 focused modules + Correlator)
      </div>
      <div class="arch-arrow">&darr;</div>
      <div class="arch-layer" style="background: rgba(248, 81, 73, 0.1); border-color: rgba(248, 81, 73, 0.3);">
        Protocol (TOON + ResponseFormatter + JSON-RPC)
      </div>
    </div>

    <p style="text-align: center; margin-top: 24px; color: var(--text-muted); font-size: 0.9rem;">
      Adding a new tool = create one module + add one line to the tool list. <a href="concepts/ARCHITECTURE.html">Read more &rarr;</a>
    </p>
  </div>
</section>

<section>
  <div class="container">
    <h2>Configuration</h2>
    <p class="section-sub">One environment variable to get started. More for fine-tuning.</p>

    <div class="config-grid">
      <div class="config-item">
        <div class="var-name">LOG_DIR</div>
        <div class="var-desc">Directory containing .log files to analyze</div>
        <div class="var-default">Default: /tmp/mcp-logs</div>
      </div>
      <div class="config-item">
        <div class="var-name">MAX_LOG_FILE_MB</div>
        <div class="var-desc">Skip files larger than this to prevent memory issues</div>
        <div class="var-default">Default: 100</div>
      </div>
      <div class="config-item">
        <div class="var-name">LOG_RETENTION_DAYS</div>
        <div class="var-desc">Auto-delete logs older than N days on startup</div>
        <div class="var-default">Default: disabled</div>
      </div>
      <div class="config-item">
        <div class="var-name">LOG_EXTRA_PATTERNS</div>
        <div class="var-desc">Additional error detection patterns (pipe-separated regex)</div>
        <div class="var-default">Merged with defaults</div>
      </div>
      <div class="config-item">
        <div class="var-name">LOG_ERROR_PATTERNS</div>
        <div class="var-desc">Override default error-level patterns entirely</div>
        <div class="var-default">Default: ERROR|EXCEPTION|TypeError|...</div>
      </div>
      <div class="config-item">
        <div class="var-name">LOG_WARN_PATTERNS</div>
        <div class="var-desc">Override default warn-level patterns entirely</div>
        <div class="var-default">Default: WARN|WARNING|deprecated|timeout</div>
      </div>
    </div>
  </div>
</section>

<section>
  <div class="container">
    <h2>Documentation</h2>
    <p class="section-sub">Guides, use cases, and reference for every workflow.</p>

    <div class="grid grid-3">
      <a href="getting-started/QUICK_START.html" class="card" style="text-decoration: none;">
        <h3>Quick Start</h3>
        <p>Get running in 5 minutes with Docker or from source.</p>
      </a>
      <a href="https://github.com/wolven-tech/mcp-log-server/blob/main/examples/README.md" class="card" style="text-decoration: none;">
        <h3>Examples Walkthrough</h3>
        <p>Debug a cascading failure step-by-step using all 9 tools.</p>
      </a>
      <a href="reference/TOOLS.html" class="card" style="text-decoration: none;">
        <h3>Tool Reference</h3>
        <p>Complete API for all 9 tools with parameters and examples.</p>
      </a>
      <a href="guides/USE_CASE_MONOREPO.html" class="card" style="text-decoration: none;">
        <h3>Use Case: Monorepo</h3>
        <p>Multi-service monorepo integration with per-service logs.</p>
      </a>
      <a href="guides/USE_CASE_INCIDENT_RESPONSE.html" class="card" style="text-decoration: none;">
        <h3>Use Case: Incident Response</h3>
        <p>Production triage workflow from pager to root cause.</p>
      </a>
      <a href="guides/USE_CASE_GCP_LOGS.html" class="card" style="text-decoration: none;">
        <h3>Use Case: GCP Cloud Logging</h3>
        <p>Working with gcloud logging read exports.</p>
      </a>
      <a href="guides/LOG_STRUCTURING.html" class="card" style="text-decoration: none;">
        <h3>Log Structuring Guide</h3>
        <p>Structure logs for maximum tool accuracy. Quality scorecard included.</p>
      </a>
      <a href="concepts/ARCHITECTURE.html" class="card" style="text-decoration: none;">
        <h3>Architecture</h3>
        <p>SOLID design, Tool behaviour, domain decomposition.</p>
      </a>
      <a href="concepts/TOON_FORMAT.html" class="card" style="text-decoration: none;">
        <h3>TOON Format</h3>
        <p>Token-Oriented Object Notation specification.</p>
      </a>
    </div>
  </div>
</section>

<section style="padding-bottom: 80px;">
  <div class="container" style="text-align: center;">
    <h2>Ready to Debug Smarter?</h2>
    <p class="section-sub">One command to install. Works with any MCP client.</p>
    <div class="install-block">
      <code><span class="dim">$</span> curl -fsSL https://raw.githubusercontent.com/wolven-tech/mcp-log-server/main/setup.sh | bash</code>
    </div>
    <div class="cta-group">
      <a href="getting-started/QUICK_START.html" class="btn btn-primary">Get Started</a>
      <a href="https://github.com/wolven-tech/mcp-log-server" class="btn btn-secondary">Star on GitHub</a>
    </div>
  </div>
</section>
