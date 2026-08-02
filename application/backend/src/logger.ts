/**
 * Minimal structured (JSON) logger writing to stdout/stderr.
 *
 * The platform's node-level OTel Collector DaemonSet
 * (gitops/apps/otel-collector/logs-daemonset.yaml) ships container stdout to
 * Loki, so one line == one JSON log record. When a log is emitted inside an
 * active span we attach `trace_id`/`span_id`; the DaemonSet's trace_parser
 * lifts those onto the OTLP log record, which is what lets Grafana pivot from a
 * Tempo trace straight to the correlated Loki logs (and back).
 */
import { context, trace } from "@opentelemetry/api";

import { config } from "./config.js";

type Level = "debug" | "info" | "warn" | "error";

const write = (level: Level, message: string, attrs?: Record<string, unknown>): void => {
  const record: Record<string, unknown> = {
    level,
    time: new Date().toISOString(),
    service: config.serviceName,
    message,
    ...attrs,
  };

  const span = trace.getSpan(context.active());
  if (span) {
    const { traceId, spanId } = span.spanContext();
    record.trace_id = traceId;
    record.span_id = spanId;
  }

  const line = JSON.stringify(record);
  if (level === "error" || level === "warn") process.stderr.write(`${line}\n`);
  else process.stdout.write(`${line}\n`);
};

export const logger = {
  debug: (message: string, attrs?: Record<string, unknown>) => write("debug", message, attrs),
  info: (message: string, attrs?: Record<string, unknown>) => write("info", message, attrs),
  warn: (message: string, attrs?: Record<string, unknown>) => write("warn", message, attrs),
  error: (message: string, attrs?: Record<string, unknown>) => write("error", message, attrs),
};
