import shell from "./catalogs/shell.ts";
import routing from "./catalogs/routing.ts";
import configuration from "./catalogs/configuration.ts";
import control from "./catalogs/control.ts";
import tools from "./catalogs/tools.ts";
import diagnostics from "./catalogs/diagnostics.ts";

import tailscale from "./catalogs/tailscale.ts";

import updates from "./catalogs/updates.ts";

export const messages: Record<string, readonly string[]> = {
  ...updates,
  ...shell,
  ...routing,
  ...configuration,
  ...control,
  ...tools,
  ...diagnostics,
  ...tailscale,
};
