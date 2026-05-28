import { type Page } from "@playwright/test";
import { test, expect } from "../../lib/fixtures";

test.use({ sourcePath: "py_console_logs/main.py", launchMode: "trace", deploymentMode: "web" });
test.setTimeout(120_000);

const tenantId = "11111111-1111-1111-1111-111111111111";
const replayId = "22222222-2222-2222-2222-222222222222";
const traceId = "trace-browser-a";
const roomId = "room-browser-a";
const inviteToken = "browser-b-token";

type CollabState = {
  status: string;
  sessionId: string;
  selectedPath: string;
  collaborationEnabled: boolean;
  peerTransportStarted: boolean;
  localOperationLogLen: number;
  grants: string[];
};

async function collabState(page: Page): Promise<CollabState> {
  return page.evaluate(() => JSON.parse((window as any).collabTestState()));
}

async function dispatchSetRegister(page: Page, value: string) {
  return page.evaluate(
    ([targetPath, nextValue]) =>
      JSON.parse((window as any).collabTestDispatchSetRegister(targetPath, nextValue)),
    ["statePane.selectedPath", value],
  );
}

async function dispatchDebugCommand(page: Page) {
  return page.evaluate(() =>
    JSON.parse((window as any).collabTestDispatchDebugCommand("step-in", "viewer-lease")),
  );
}

function joinBootstrap(origin: string) {
  return {
    replayId,
    traceId,
    traceIdentity: traceId,
    roomId,
    initialGrants: ["observe", "publishAwareness"],
    webUiUrl: `https://web.codetracer.com/collab/join/${inviteToken}`,
    nativeJoinUrl: `https://web.codetracer.com/collab/join/${inviteToken}`,
    rendezvousUrl: `${origin}/api/v1/collab/rooms/${roomId}/rendezvous`,
    transportHints: ["control-plane-only", "control-plane-rendezvous", "browser-channel", "viewops-not-accepted"],
  };
}

test("e2e_collab_webui_invite_browser_ab_transport", async ({
  ctPage,
}) => {
  const origin = new URL(ctPage.url()).origin;
  const context = ctPage.context();
  const ciViewOpPayloads: unknown[] = [];
  const rendezvousPayloads: unknown[] = [];
  let createRequests = 0;
  let exchangeRequests = 0;

  await context.route("**/api/v1/tenants/*/replays/*/collab/invites", async (route) => {
    createRequests += 1;
    const body = route.request().postDataJSON() as { grantPreset?: string };
    expect(body.grantPreset).toBe("Viewer");
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        inviteId: "33333333-3333-3333-3333-333333333333",
        joinUrl: `https://web.codetracer.com/collab/join/${inviteToken}`,
        roomId,
        grantPreset: "Viewer",
        grants: ["observe", "publishAwareness"],
        expiresAt: "2026-05-28T12:00:00Z",
      }),
    });
  });

  await context.route("**/api/v1/collab/invites/exchange", async (route) => {
    exchangeRequests += 1;
    const body = route.request().postDataJSON() as { token?: string };
    expect(body.token).toBe(inviteToken);
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify(joinBootstrap(origin)),
    });
  });

  await context.route("**/api/v1/collab/rooms/*/rendezvous", async (route) => {
    const body = route.request().postDataJSON() as {
      inviteToken?: string;
      payload?: Record<string, unknown>;
    };
    rendezvousPayloads.push(body.payload ?? {});
    const raw = JSON.stringify(body.payload ?? {});
    if (/viewop|operationLog|"opId"|"kind"/i.test(raw)) {
      ciViewOpPayloads.push(body.payload);
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        roomId,
        rendezvousUrl: `${origin}/api/v1/collab/rooms/${roomId}/rendezvous`,
        transportHints: ["control-plane-only", "control-plane-rendezvous", "browser-channel", "viewops-not-accepted"],
        acceptsViewOps: false,
      }),
    });
  });

  await ctPage.evaluate(
    ([tenant, replay, trace]) => {
      window.localStorage.setItem("CODETRACER_TENANT_ID", tenant);
      window.localStorage.setItem("CODETRACER_REPLAY_ID", replay);
      (window as any).CODETRACER_TENANT_ID = tenant;
      (window as any).CODETRACER_REPLAY_ID = replay;
      (window as any).CODETRACER_TRACE_ID = trace;
    },
    [tenantId, replayId, traceId],
  );

  await expect.poll(() => collabState(ctPage)).toMatchObject({
    status: "ready",
  });

  const invite = await ctPage.evaluate(
    ([tenant, replay]) => (window as any).__ctTestCreateCollabInvite("Viewer", tenant, replay),
    [tenantId, replayId],
  );
  expect(invite).toMatchObject({
    joinUrl: `https://web.codetracer.com/collab/join/${inviteToken}`,
    roomId,
    grantPreset: "Viewer",
  });
  expect(createRequests).toBe(1);

  await expect
    .poll(() => ctPage.evaluate(() => (window as any).CODETRACER_COLLAB_HOST_SESSION))
    .toMatchObject({
      activated: true,
      roomId,
      replayId,
      transportStarted: true,
      acceptsViewOpsThroughCi: false,
    });

  await expect.poll(() => collabState(ctPage)).toMatchObject({
    sessionId: roomId,
    collaborationEnabled: true,
    peerTransportStarted: true,
  });

  const beforeJoin = await dispatchSetRegister(ctPage, "locals.beforeJoin");
  expect(beforeJoin).toMatchObject({
    status: "asApplied",
    publishedToPeer: true,
  });

  const joinPage = await context.newPage();
  await joinPage.goto(`${origin}/collab/join/${inviteToken}`);

  await expect
    .poll(async () => ({
      exchangeRequests,
      session: await joinPage.evaluate(() => (window as any).CODETRACER_COLLAB_SESSION ?? null),
      state: await collabState(joinPage),
      transportApply: await joinPage.evaluate(() => (window as any).CODETRACER_COLLAB_TRANSPORT_APPLY ?? []),
    }))
    .toMatchObject({
      exchangeRequests: 1,
      session: {
        activated: true,
        roomId,
        replayId,
        transportStarted: true,
        acceptsViewOpsThroughCi: false,
        canDrive: false,
      },
      state: {
        sessionId: roomId,
        selectedPath: "locals.beforeJoin",
        collaborationEnabled: true,
        peerTransportStarted: true,
        grants: ["capObserve", "capPublishAwareness"],
      },
    });

  await expect
    .poll(() =>
      joinPage.evaluate(() =>
        ((window as any).CODETRACER_COLLAB_TRANSPORT_APPLY ?? []).some(
          (entry: { kind?: string; status?: string }) =>
            entry.kind === "snapshotTail" && String(entry.status).includes("applied=1"),
        ),
      ),
    )
    .toBe(true);

  const viewerMutation = await dispatchSetRegister(joinPage, "locals.viewerBlocked");
  expect(viewerMutation).toMatchObject({
    status: "asRejected",
    publishedToPeer: false,
    localOnly: true,
    selectedPath: "locals.beforeJoin",
  });

  const viewerDebug = await dispatchDebugCommand(joinPage);
  expect(viewerDebug).toMatchObject({
    status: "asRejected",
    publishedToPeer: false,
    localOnly: true,
  });

  const afterJoin = await dispatchSetRegister(ctPage, "locals.afterJoin");
  expect(afterJoin).toMatchObject({
    status: "asApplied",
    publishedToPeer: true,
  });

  await expect.poll(() => collabState(joinPage)).toMatchObject({
    selectedPath: "locals.afterJoin",
  });
  await expect
    .poll(() =>
      joinPage.evaluate(() =>
        ((window as any).CODETRACER_COLLAB_TRANSPORT_LOG ?? []).some(
          (entry: { direction?: string; kind?: string; opId?: string }) =>
            entry.direction === "receive" && entry.kind === "viewop",
        ),
      ),
    )
    .toBe(true);

  expect(rendezvousPayloads).toHaveLength(1);
  expect(ciViewOpPayloads).toHaveLength(0);
});
