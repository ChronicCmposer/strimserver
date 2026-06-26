import streamDeck from "@elgato/streamdeck";
import { Endpoints } from "./config";
import type { ControllerStatus } from "./types";

type StatusHandler = (status: ControllerStatus) => void;
type StateHandler  = (connected: boolean) => void;

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 10_000;

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

      ws.addEventListener("open", () => {
         this.#backoff = RECONNECT_MIN_MS;       // reset backoff on a clean connect
         this.#setConnected(true);
      });

      ws.addEventListener("message", (ev: MessageEvent) => {
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

      ws.addEventListener("close", () => {
         this.#ws = null;
         this.#setConnected(false);
         if (!this.#closedByUs) this.#scheduleReconnect();
      });

      ws.addEventListener("error", () => {
         // 'close' fires after 'error'; let the close handler drive reconnect.
         streamDeck.logger.debug("status-stream: socket error");
      });
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
      this.#ws?.close();
      this.#ws = null;
      this.#setConnected(false);
      this.#last = null;
      this.#backoff = RECONNECT_MIN_MS;
   }
}

// One instance for the whole plugin process.
export const statusStream = new StatusStream();
