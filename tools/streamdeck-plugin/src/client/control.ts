import { Endpoints } from "./config";
import type { ControlComponent, ControlAction } from "./types";

export type ControlResult =
   | { kind: "ok" }
   | { kind: "rejected"; status: number; message: string }   // server replied with an error
   | { kind: "unreachable"; cause: Error };                  // network / DNS / refused

export async function sendControl(
   component: ControlComponent,
   action:    ControlAction,
   signal?:   AbortSignal,
): Promise<ControlResult> {
   try {
      const r = await fetch(Endpoints.control(), {
         method:  "POST",
         headers: { "Content-Type": "application/json" },
         body:    JSON.stringify({ component, action }),
         signal,
      });
      if (r.status === 204) return { kind: "ok" };
      const message = (await r.text()).trim() || `HTTP ${r.status}`;
      return { kind: "rejected", status: r.status, message };
   } catch (e) {
      return { kind: "unreachable", cause: e as Error };
   }
}
