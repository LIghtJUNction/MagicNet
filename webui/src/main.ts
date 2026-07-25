import { createApp } from "vue";
import App from "./App.vue";
import { bootstrapTheme } from "@/composables/useTheme";
import "./styles.css";

bootstrapTheme();
createApp(App).mount("#app");
