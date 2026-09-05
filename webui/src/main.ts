import { createApp } from "vue";
import App from "./App.vue";
import { installMagicNetFavicon } from "@/branding";
import { bootstrapTheme } from "@/composables/useTheme";
import "./styles.css";
import "./console.css";

installMagicNetFavicon();
bootstrapTheme();
createApp(App).mount("#app");
