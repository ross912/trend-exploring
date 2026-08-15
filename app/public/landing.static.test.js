#!/usr/bin/env node
/* Lightweight contract checks for the public landing/auth assets. */
const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = __dirname;
const read = (name) => fs.readFileSync(path.join(root, name), "utf8");
const landing = read("landing.html");
const login = read("login.html");
const landingCss = read("landing.css");
const loginCss = read("login.css");
const landingJs = read("landing.js");
const loginJs = read("login.js");

assert.match(landing, /name="viewport"[^>]+width=device-width/);
assert.match(landing, /class="landing-entry"[^>]+href="\/app"/);
assert.match(landing, /src="\/landing\.js"/);
assert.match(landingCss, /landing-hero-v1\.webp/);
assert.match(landingCss, /prefers-reduced-motion/);
assert.match(landingJs, /event\.key !== "Enter"/);
assert.match(landingJs, /Spacebar|code === "Space"/);
assert.doesNotMatch(landing, /wordmark-dot|PUBLIC ENTRY|ACCESS \/ 0[12]/);
assert.doesNotMatch(landing, /[·—–]/);
assert.doesNotMatch(login, /[·—–]/);

assert.match(login, /name="username"[^>]+autocomplete="username"/);
assert.match(login, /name="password"[^>]+autocomplete="current-password"/);
assert.match(login, /name="recovery_code"[^>]+autocomplete="one-time-code"/);
assert.match(login, /name="new_password"[^>]+autocomplete="new-password"/);
assert.match(login, /data-endpoint="\/api\/auth\/login"/);
assert.match(login, /role="alert"/);
assert.match(loginCss, /prefers-color-scheme: dark/);
assert.match(loginCss, /prefers-reduced-motion/);
assert.match(loginJs, /response\.status === 429/);
assert.match(loginJs, /\/api\/auth\/recovery/);
assert.match(loginJs, /new_password/);

for (const source of [landing, login, landingCss, loginCss, landingJs, loginJs]) {
  assert.doesNotMatch(source, /https?:\/\//, "public assets must not load external URLs");
  assert.doesNotMatch(source, /googletagmanager|google-analytics|segment\.com/i, "tracking is not allowed");
}

const hero = path.join(root, "assets", "landing-hero-v1.webp");
const heroBytes = fs.statSync(hero).size;
assert.ok(heroBytes > 0 && heroBytes < 250000, `hero WebP should stay compact (${heroBytes} bytes)`);
assert.equal(fs.readFileSync(hero).subarray(0, 4).toString("ascii"), "RIFF");
console.log("landing.static.test: ok");
