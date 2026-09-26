import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
export default defineConfig({ plugins:[vue()], base:'./', build:{target:'es2022',outDir:'dist',emptyOutDir:true}, server:{host:'127.0.0.1'} });
