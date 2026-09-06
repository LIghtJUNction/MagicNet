import { createApp } from "vue";
import App from "./App.vue";
import { installMagicNetFavicon } from "@/branding";
import { bootstrapTheme } from "@/composables/useTheme";
import { bootstrapLocale } from "@/i18n";
import "./styles.css";

installMagicNetFavicon();
bootstrapTheme();
bootstrapLocale();
createApp(App).mount("#app");
