// OpenClaw plugin: registers the six webex.* tools as GOVERNED OpenClaw tools.
// Each tool call passes the agent-control plugin's gate (deny/steer) and is audited
// to Splunk + traced to Galileo, for free, because it's a normal OpenClaw tool call.
// Attach mechanism: api.registerTool (confirmed via the plugin SDK). BYO-per-user:
// the Webex creds live in the user's own settings file (see webex-client.mjs).
import { Type } from "@sinclair/typebox";
import { webex, isConfigured, resolveRoomId } from "./webex-client.mjs";

const text = (s) => ({ content: [{ type: "text", text: typeof s === "string" ? s : JSON.stringify(s, null, 2) }] });
const ok = (data, summary) => ({ ...text(summary ?? data), details: data });
const err = (e) => ({ ...text(`Webex error: ${e.message}`), details: { error: e.message } });

// wrap a webex op as a tool.execute, with a not-configured guard
const run = (fn) => async (_toolCallId, params) => {
  if (!isConfigured()) return err(new Error("Webex is not configured for this user (set creds + run OAuth)"));
  try { return ok(await fn(params || {})); } catch (e) { return err(e); }
};

const TOOLS = [
  {
    label: "Webex: spaces", name: "webex_list_spaces",
    description: "List the Webex spaces (rooms) you belong to.",
    parameters: Type.Object({ max: Type.Optional(Type.Number({ description: "max spaces (default 50)" })) }),
    execute: run((p) => webex.list_spaces(p)),
  },
  {
    label: "Webex: messages", name: "webex_list_messages",
    description: "List recent messages in a Webex space. Pass the space NAME or its id as 'room' (a name is resolved to the id automatically). Set mentionedMe=true for only messages that @mention you.",
    parameters: Type.Object({
      room: Type.String({ description: "space name or roomId" }),
      mentionedMe: Type.Optional(Type.Boolean()),
      max: Type.Optional(Type.Number()),
    }),
    execute: run(async (p) => webex.list_messages({ roomId: await resolveRoomId(p.room), mentionedMe: p.mentionedMe, max: p.max })),
  },
  {
    label: "Webex: direct", name: "webex_list_direct",
    description: "List the 1:1 direct-message thread with a person (by email or personId).",
    parameters: Type.Object({
      personEmail: Type.Optional(Type.String()),
      personId: Type.Optional(Type.String()),
      max: Type.Optional(Type.Number()),
    }),
    execute: run((p) => webex.list_direct(p)),
  },
  {
    label: "Webex: transcripts", name: "webex_list_transcripts",
    description: "List available meeting transcripts (plain text the model can read).",
    parameters: Type.Object({
      meetingId: Type.Optional(Type.String()),
      max: Type.Optional(Type.Number()),
    }),
    execute: run((p) => webex.list_transcripts(p)),
  },
  {
    // WRITE, higher-risk. Governance holds sends behind approval; never auto-send.
    label: "Webex: send", name: "webex_send_message",
    description: "Send a Webex message. WRITE action, only after explicit human approval; drafting is safe, sending is not.",
    parameters: Type.Object({
      roomId: Type.Optional(Type.String()),
      toPersonEmail: Type.Optional(Type.String()),
      text: Type.String(),
      markdown: Type.Optional(Type.String()),
    }),
    execute: run((p) => webex.send_message(p)),
  },
  {
    // WRITE, higher-risk.
    label: "Webex: book meeting", name: "webex_book_meeting",
    description: "Book a Webex meeting. WRITE action, only after explicit human approval.",
    parameters: Type.Object({
      title: Type.String(),
      start: Type.String({ description: "ISO 8601 start" }),
      end: Type.String({ description: "ISO 8601 end" }),
      invitees: Type.Optional(Type.Array(Type.Object({ email: Type.String() }))),
    }),
    execute: run((p) => webex.book_meeting(p)),
  },
];

const entry = {
  id: "openclaw-webex",
  name: "Webex",
  description: "Governed Webex tools (read spaces/messages/transcripts; send/book behind approval).",
  register(api) {
    for (const tool of TOOLS) api.registerTool(tool);
  },
};

export default entry;
