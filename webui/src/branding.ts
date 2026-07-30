import magicNetLogoUrl from "../../icon.png?url";

export const MAGICNET_LOGO_URL = magicNetLogoUrl;

export function installMagicNetFavicon(): void {
  const favicon = document.querySelector<HTMLLinkElement>("#magicnet-favicon");
  if (!favicon) return;

  favicon.href = MAGICNET_LOGO_URL;
}
