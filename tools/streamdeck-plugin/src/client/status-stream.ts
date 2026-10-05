import streamDeck from "@elgato/streamdeck";
import { BUILD_COMMIT, BUILD_VERSION } from "./build-info";
import { Endpoints } from "./config";
import type { ControllerStatus } from "./types";
import { formatBuild, isDevVersion, shortCommit, versionMismatch } from "./version";

type StatusHandler = (status: ControllerStatus) => void;
type StateHandler  = (connected: boolean) => void;

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 10_000;
// A connection must stay up this long (or deliver a message) before we treat
// it as healthy and reset the reconnect backoff.
const STABLE_CONNECTION_MS = 5_000;

// Version probe: short enough to never stall the stream, long enough for a
// healthy localhost controller to answer.
const VERSION_PROBE_TIMEOUT_MS = 2_000;
const VERSION_HEADER = "X-Strimserver-Version";
const COMMIT_HEADER = "X-Strimserver-Commit";

type ServerBuild = { version: string; commit: string | null };

/** One best-effort header read; null on network error or a missing version header. */
async function fetchServerBuild(url: string): Promise<ServerBuild | null> {
   try {
      const res = await fetch(url, { signal: AbortSignal.timeout(VERSION_PROBE_TIMEOUT_MS) });
      // Headers.get is case-insensitive, so the wire casing does not matter.
      const version = res.headers.get(VERSION_HEADER);
      if (version === null) return null;
      return { version, commit: res.headers.get(COMMIT_HEADER) };
   } catch {
      return null;
   }
}

/**
 * Fire-and-forget probe of the server's reported build, run once per socket
 * open. Never blocks the caller and never rejects: any failure degrades to a
 * single INFO line. Only real-vs-real semver differences warn.
 */
async function probeServerVersion(): Promise<void> {
   try {
      const build = await fetchServerBuild(Endpoints.healthz()) ?? await fetchServerBuild(Endpoints.status());
      if (build === null) {
         streamDeck.logger.info("status-stream: server version unknown");
         return;
      }
      const serverCommit = build.commit ?? "unknown";
      streamDeck.logger.info(`status-stream: server strimserver ${formatBuild(build.version, serverCommit)}`);

      if (versionMismatch(BUILD_VERSION, build.version)) {
         streamDeck.logger.warn(
            `status-stream: version mismatch: plugin ${formatBuild(BUILD_VERSION, BUILD_COMMIT)} ` +
            `vs server ${formatBuild(build.version, serverCommit)}`,
         );
         return;
      }
      const bothReal = !isDevVersion(BUILD_VERSION) && !isDevVersion(build.version);
      if (bothReal && BUILD_COMMIT !== "unknown" && serverCommit !== "unknown" && BUILD_COMMIT !== serverCommit) {
         streamDeck.logger.info(
            `status-stream: commit differs: plugin ${shortCommit(BUILD_COMMIT)} vs server ${shortCommit(serverCommit)}`,
         );
      }
   } catch (e) {
      streamDeck.logger.info(`status-stream: server version probe failed: ${String(e)}`);
   }
}

/** Best-effort, never-throwing description of an ErrorEvent for diagnostics. */
function describeSocketError(ev: Event): string {
   const parts: string[] = [`type=${ev.type}`];
   const e = ev as unknown as { error?: unknown; message?: unknown };

   if (e.error !== undefined && e.error !== null) {
      parts.push(`error=${formatUnknown(e.error)}`);
      const cause = (e.error as { cause?: unknown }).cause;
      if (cause !== undefined && cause !== null) parts.push(`cause=${formatUnknown(cause)}`);
   }
   if (typeof e.message === "string" && e.message !== "") parts.push(`message=${e.message}`);

   // undici often dispatches a bare ErrorEvent with no detail on an abrupt TCP
   // close after a clean upgrade; say so rather than emitting nothing useful.
   if (parts.length === 1) parts.push("no error detail (abrupt close?)");
   return parts.join(" ");
}

function formatUnknown(value: unknown): string {
   if (value instanceof Error) return `${value.name}: ${value.message}`;
   if (typeof value === "string") return value;
   try {
      return JSON.stringify(value);
   } catch {
      return String(value);
   }
}

/**
 * A single, shared, self-healing subscription to the controller's /subscribe
 * WebSocket. Subscribers register handlers; the stream connects lazily on the
 * first subscriber and disconnects when the last one leaves.
 */
class StatusStream {
   #ws: WebSocket | null = null;
   #statusHandlers = new Set<StatusHandler>();
   #stateHandlers  = new Set<StateHandler>();
   #last: ControllerStatus | null = null;
   #connected = false;
   #backoff = RECONNECT_MIN_MS;
   #reconnectTimer: ReturnType<typeof setTimeout> | null = null;
   #stableTimer: ReturnType<typeof setTimeout> | null = null;
   #closedByUs = false;

   /** Latest status seen, or null if we've never received one. */
   get last(): ControllerStatus | null { return this.#last; }
   get connected(): boolean { return this.#connected; }

   onStatus(h: StatusHandler): () => void {
      this.#statusHandlers.add(h);
      if (this.#last) h(this.#last);            // replay latest to a late subscriber
      this.#ensureConnected();
      return () => this.#statusHandlers.delete(h);
   }

   onConnectionState(h: StateHandler): () => void {
      this.#stateHandlers.add(h);
      h(this.#connected);
      return () => this.#stateHandlers.delete(h);
   }

   /** Drop the connection if nobody is listening any more. */
   releaseIfIdle(): void {
      if (this.#statusHandlers.size === 0 && this.#stateHandlers.size === 0) {
         this.#teardown();
      }
   }

   #ensureConnected(): void {
      if (this.#ws || this.#reconnectTimer) return;
      this.#connect();
   }

   #connect(): void {
      this.#closedByUs = false;
      const url = Endpoints.subscribe();
      streamDeck.logger.info(`status-stream: connecting to ${url}`);

      let ws: WebSocket;
      try {
         ws = new WebSocket(url);
      } catch (e) {
         streamDeck.logger.error(`status-stream: construct failed: ${String(e)}`);
         this.#scheduleReconnect();
         return;
      }
      this.#ws = ws;

      // Per-connection lifecycle, captured by the listeners below.
      let openedAt: number | null = null;
      let gotMessage = false;

      ws.addEventListener("open", () => {
         openedAt = Date.now();
         this.#setConnected(true);
         // Best-effort, fire-and-forget: a slow/failed probe must never affect
         // the connection or the reconnect/backoff/stable-timer logic.
         void probeServerVersion();
         // Only reset the backoff once the connection proves stable: a server
         // that accepts then immediately drops must not pin the loop at 500ms.
         this.#stableTimer = setTimeout(() => {
            this.#stableTimer = null;
            this.#backoff = RECONNECT_MIN_MS;
         }, STABLE_CONNECTION_MS);
      });

      ws.addEventListener("message", (ev: MessageEvent) => {
         if (!gotMessage) {
            gotMessage = true;
            this.#clearStableTimer();
            this.#backoff = RECONNECT_MIN_MS;    // a delivered message proves health
         }
         let status: ControllerStatus;
         try {
            status = JSON.parse(String(ev.data)) as ControllerStatus;
         } catch (e) {
            streamDeck.logger.warn(`status-stream: bad json: ${String(e)}`);
            return;
         }
         this.#last = status;
         for (const h of this.#statusHandlers) h(status);
      });

      ws.addEventListener("close", (ev: CloseEvent) => {
         this.#clearStableTimer();
         const wasOpen = openedAt !== null;
         const openForMs = openedAt === null ? 0 : Date.now() - openedAt;
         const how = wasOpen ? "dropped after open" : "failed to connect";
         streamDeck.logger.info(
            `status-stream: socket ${how}: code=${ev.code} reason=${JSON.stringify(ev.reason)} wasOpen=${wasOpen} openForMs=${openForMs}`,
         );
         this.#ws = null;
         this.#setConnected(false);
         if (!this.#closedByUs) this.#scheduleReconnect();
      });

      ws.addEventListener("error", (ev: Event) => {
         // undici dispatches an ErrorEvent; the underlying exception lives in
         // `.error` (e.g. `TypeError: connect ECONNREFUSED ...:4000`) with a
         // possible `.cause`, while `.message` defaults to "". Log all of it at
         // INFO so the reconnect loop's failure reason is visible in the logs.
         streamDeck.logger.info(`status-stream: socket error: ${describeSocketError(ev)}`);
         // 'close' fires after 'error'; let the close handler drive reconnect.
      });
   }

   #clearStableTimer(): void {
      if (this.#stableTimer) { clearTimeout(this.#stableTimer); this.#stableTimer = null; }
   }

   #scheduleReconnect(): void {
      if (this.#reconnectTimer) return;
      const delay = this.#backoff;
      this.#backoff = Math.min(this.#backoff * 2, RECONNECT_MAX_MS);
      streamDeck.logger.info(`status-stream: reconnecting in ${delay}ms`);
      this.#reconnectTimer = setTimeout(() => {
         this.#reconnectTimer = null;
         if (this.#statusHandlers.size > 0 || this.#stateHandlers.size > 0) {
            this.#connect();
         }
      }, delay);
   }

   #setConnected(value: boolean): void {
      if (this.#connected === value) return;
      this.#connected = value;
      for (const h of this.#stateHandlers) h(value);
   }

   #teardown(): void {
      this.#closedByUs = true;
      if (this.#reconnectTimer) { clearTimeout(this.#reconnectTimer); this.#reconnectTimer = null; }
      this.#clearStableTimer();
      this.#ws?.close();
      this.#ws = null;
      this.#setConnected(false);
      this.#last = null;
      this.#backoff = RECONNECT_MIN_MS;
   }
}

// One instance for the whole plugin process.
export const statusStream = new StatusStream();
