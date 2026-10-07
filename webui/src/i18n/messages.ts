import frontend from "./catalogs/frontend.ts";
import overrides from "./catalogs/overrides.ts";
import moduleUpdate from "./catalogs/module-update.ts";
import shell from "./catalogs/shell.ts";
import routing from "./catalogs/routing.ts";
import configuration from "./catalogs/configuration.ts";
import control from "./catalogs/control.ts";
import tools from "./catalogs/tools.ts";
import diagnostics from "./catalogs/diagnostics.ts";
import routeFeedback from "./catalogs/route-feedback.ts";
import machineStatus from "./catalogs/machine-status.ts";

import tailscale from "./catalogs/tailscale.ts";
import terminal from "./catalogs/terminal.ts";

export const messages: Record<string, readonly string[]> = {
  ...frontend,
  ...shell,
  ...routing,
  ...configuration,
  ...control,
  ...tools,
  ...diagnostics,
  ...routeFeedback,
  ...machineStatus,
  ...tailscale,
  ...terminal,
  ...overrides,
  ...moduleUpdate,
};
