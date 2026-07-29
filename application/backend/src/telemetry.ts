/**
 * OpenTelemetry bootstrap.
 *
 * MUST be evaluated before any instrumented library (http, express, ...) is
 * imported, so the auto-instrumentations can patch them. That is guaranteed by
 * loading this module with Node's `--import` flag:
 *
 *   node --import ./dist/telemetry.js dist/index.js
 *
 * Signals are exported over OTLP/HTTP to the platform's gateway collector
 * (see gitops/apps/otel-collector), which fans out traces -> Tempo,
 * metrics -> Prometheus, logs -> Loki. Container stdout (structured JSON from
 * logger.ts) is shipped to Loki by the node-level collector DaemonSet, so we
 * deliberately do not also push logs over OTLP from here (avoids duplication).
 */
import { diag, DiagConsoleLogger, DiagLogLevel } from "@opentelemetry/api";
import { getNodeAutoInstrumentations } from "@opentelemetry/auto-instrumentations-node";
import { OTLPMetricExporter } from "@opentelemetry/exporter-metrics-otlp-http";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import {
  ConsoleMetricExporter,
  PeriodicExportingMetricReader,
  type PushMetricExporter,
} from "@opentelemetry/sdk-metrics";
import { NodeSDK } from "@opentelemetry/sdk-node";
import { ConsoleSpanExporter, type SpanExporter } from "@opentelemetry/sdk-trace-node";
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from "@opentelemetry/semantic-conventions";

import { config } from "./config.js";

diag.setLogger(
  new DiagConsoleLogger(),
  config.otel.debug ? DiagLogLevel.DEBUG : DiagLogLevel.WARN,
);

const endpoint = config.otel.endpoint.replace(/\/+$/, "");

const resource = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: config.serviceName,
  [ATTR_SERVICE_VERSION]: config.serviceVersion,
  // Stable-incubating key; string literal avoids the /incubating subpath.
  "deployment.environment.name": config.environment,
});

const traceExporter: SpanExporter = config.otel.debug
  ? new ConsoleSpanExporter()
  : new OTLPTraceExporter({ url: `${endpoint}/v1/traces` });

const metricExporter: PushMetricExporter = config.otel.debug
  ? new ConsoleMetricExporter()
  : new OTLPMetricExporter({ url: `${endpoint}/v1/metrics` });

const sdk = new NodeSDK({
  resource,
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15_000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      // fs spans are extremely noisy and rarely actionable.
      "@opentelemetry/instrumentation-fs": { enabled: false },
    }),
  ],
});

sdk.start();

let shuttingDown = false;

/** Flush and shut down the OpenTelemetry SDK. Safe to call more than once. */
export async function shutdownTelemetry(): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  try {
    await sdk.shutdown();
  } catch (err) {
    // Never let telemetry teardown mask the real shutdown reason.
    diag.error("OpenTelemetry shutdown failed", err as Error);
  }
}
