import streamDeck, {
   action,
   SingletonAction,
   type KeyDownEvent,
   type WillAppearEvent,
   type WillDisappearEvent,
} from "@elgato/streamdeck";

import { statusStream } from "../client/status-stream";
import { sendControl } from "../client/control";
import { Stages, stageUIState, type ControllerStatus, type StageUIState } from "../client/types";

@action({ UUID: "com.chroniccmposer.strimserver.egress" })
export class EgressToggle extends SingletonAction {
   #visible = 0;
   #unsubStatus?: () => void;
   #unsubConn?: () => void;
   #uiState: StageUIState = "unknown";
   #connected = false;

   override onWillAppear(_ev: WillAppearEvent): void {
      if (++this.#visible === 1) {
         this.#unsubStatus = statusStream.onStatus((s) => this.#applyStatus(s));
         this.#unsubConn   = statusStream.onConnectionState((c) => {
            this.#connected = c;
            void this.#render();
         });
      }
      void this.#render();
   }

   override onWillDisappear(_ev: WillDisappearEvent): void {
      if (--this.#visible === 0) {
         this.#unsubStatus?.(); this.#unsubStatus = undefined;
         this.#unsubConn?.();   this.#unsubConn   = undefined;
         statusStream.releaseIfIdle();
      }
   }

   override async onKeyDown(ev: KeyDownEvent): Promise<void> {
      // Decide from last-known actual state; never pre-flip the button.
      const goingTo = this.#uiState === "on" || this.#uiState === "starting" ? "stop" : "start";
      const result = await sendControl("scale_and_egress", goingTo);

      switch (result.kind) {
         case "ok":
            // Do nothing: the controller will push the new status over the WS.
            break;
         case "rejected":
            streamDeck.logger.warn(`control ${goingTo} rejected: ${result.message}`);
            await ev.action.showAlert();          // e.g. "normalized path is not ready"
            break;
         case "unreachable":
            streamDeck.logger.error(`control ${goingTo} unreachable: ${result.cause.message}`);
            await ev.action.showAlert();
            break;
      }
   }

   #applyStatus(s: ControllerStatus): void {
      this.#uiState = stageUIState(s.stages[Stages.ScaleAndEgress]);
      void this.#render();
   }

   async #render(): Promise<void> {
      // Update every visible instance of this action.
      for (const act of this.actions) {
         if (!act.isKey()) continue;
         if (!this.#connected) {
            await act.setState(0);
            await act.setTitle("⚠");
            continue;
         }
         switch (this.#uiState) {
            case "on":       await act.setState(1); await act.setTitle("");      break;
            case "off":      await act.setState(0); await act.setTitle("");      break;
            case "starting": await act.setState(1); await act.setTitle("…");     break;
            case "stopping": await act.setState(0); await act.setTitle("…");     break;
            case "unknown":  await act.setState(0); await act.setTitle("?");     break;
         }
      }
   }
}
