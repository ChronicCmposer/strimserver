import streamDeck from "@elgato/streamdeck";
import { EgressToggle } from "./actions/egress-toggle";

streamDeck.actions.registerAction(new EgressToggle());
streamDeck.connect();
