import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const rankingPath = resolve("src/MagicNet/webroot/ranking.json");

function input(name, fallback = "") {
  return process.env[`INPUT_${name.replaceAll("-", "_").toUpperCase()}`] || fallback;
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

function parseAmount(value) {
  const normalized = value.replace(/[,\s￥¥]/g, "").replace(/^CNY/i, "");
  const amount = Number(normalized);
  if (!Number.isFinite(amount) || amount < 0) {
    throw new Error(`Invalid donation amount: ${value}`);
  }
  return Math.round(amount * 100) / 100;
}

function formatAmount(amount, currency) {
  const text = Number.isInteger(amount) ? String(amount) : amount.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
  if (currency === "CNY") return `¥${text}`;
  return `${text} ${currency}`;
}

function slug(value) {
  const ascii = value
    .normalize("NFKD")
    .replace(/[^\p{L}\p{N}]+/gu, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
  return ascii || "supporter";
}

function stableId(name, date, amount) {
  const hash = createHash("sha256")
    .update(`${name}\n${date}\n${amount}`)
    .digest("hex")
    .slice(0, 8);
  return `${slug(name)}-${date.replaceAll("-", "")}-${hash}`;
}

function existingAmount(entry) {
  if (typeof entry.amountValue === "number") return entry.amountValue;
  const text = String(entry.amount || "");
  const match = text.match(/[0-9]+(?:\.[0-9]+)?/);
  return match ? Number(match[0]) : 0;
}

function sortEntries(entries) {
  return entries
    .sort((a, b) => {
      const amountDelta = existingAmount(b) - existingAmount(a);
      if (amountDelta) return amountDelta;
      const dateDelta = String(b.date || "").localeCompare(String(a.date || ""));
      if (dateDelta) return dateDelta;
      return String(a.name || "").localeCompare(String(b.name || ""), "zh-CN");
    })
    .map((entry, index) => ({ ...entry, rank: index + 1 }));
}

const name = input("name").trim();
const amountInput = input("amount").trim();
const message = input("message").trim();
const date = input("date").trim() || today();
const currency = (input("currency", "CNY").trim() || "CNY").toUpperCase();
const requestedId = input("supporter-id").trim();

if (!name) throw new Error("Missing required input: name");
if (!amountInput) throw new Error("Missing required input: amount");
if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) throw new Error(`Invalid date, expected YYYY-MM-DD: ${date}`);

const amountValue = parseAmount(amountInput);
const id = requestedId || stableId(name, date, amountValue);
const ranking = JSON.parse(await readFile(rankingPath, "utf8"));
const entries = Array.isArray(ranking.entries) ? ranking.entries : [];
const nextEntry = {
  id,
  name,
  amount: formatAmount(amountValue, currency),
  amountValue,
  currency,
  message: message || "感谢支持 MagicNet。",
  date
};

const index = entries.findIndex((entry) => entry.id === id);
if (index >= 0) {
  entries[index] = { ...entries[index], ...nextEntry };
} else {
  entries.push(nextEntry);
}

ranking.updatedAt = today();
ranking.entries = sortEntries(entries);

await writeFile(rankingPath, `${JSON.stringify(ranking, null, 2)}\n`);

console.log(`ranking_id=${id}`);
console.log(`ranking_entries=${ranking.entries.length}`);
