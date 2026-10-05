import streamDeck from "@elgato/streamdeck";
import { EgressToggle } from "./actions/egress-toggle";
import { BUILD_COMMIT, BUILD_VERSION } from "./client/build-info";
import { formatBuild } from "./client/version";

streamDeck.logger.info(`plugin: strimserver-streamdeck ${formatBuild(BUILD_VERSION, BUILD_COMMIT)}`);
streamDeck.actions.registerAction(new EgressToggle());
streamDeck.connect();
