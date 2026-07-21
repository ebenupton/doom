#!/usr/bin/env node
// tubebeeb — headless jsbeeb driver WITH 6502 second-processor support.
//
// The jsbeeb-mcp server cannot enable the Tube (its create_machine model
// enum has no copro option and MachineSession doesn't forward opts.tube),
// but the underlying jsbeeb library supports it fully: fake6502.js honors
// model.tube, and findModel() returns SHARED Model instances — so mutating
// findModel('B-DFS1.2').tube before constructing the session is all it
// takes. This script drives the same MachineSession the MCP uses, plus
// that one mutation.
//
// Usage:
//   node tools/tubebeeb.mjs [--tube] [--disc image.ssd] --script "cmd; cmd; ..."
// Commands:
//   boot                 SHIFT+hard-reset, hold SHIFT for 1.5M cycles (autoboot)
//   waitprompt [secs]    run until keyboard-input prompt, print captured text
//   run <cycles>         run N host CPU cycles (2MHz)
//   key <NAME> down|up   press/release (UP DOWN LEFT RIGHT SHIFT RETURN SPACE A-Z 0-9)
//   shot <file.png>      write a screenshot (active area, 2x)
//   mem <hexaddr> <len>  hex dump of host memory
//   pmem <hexaddr> <len> hex dump of PARASITE memory (tube only)
//   text                 print captured VDU text output
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { pathToFileURL } from "node:url";

function findJsbeeb() {
    if (process.env.JSBEEB_PATH) return process.env.JSBEEB_PATH;
    const npx = path.join(os.homedir(), ".npm/_npx");
    const hits = [];
    if (fs.existsSync(npx))
        for (const d of fs.readdirSync(npx)) {
            const p = path.join(npx, d, "node_modules/jsbeeb");
            if (fs.existsSync(path.join(p, "package.json"))) hits.push(p);
        }
    if (!hits.length) throw new Error("jsbeeb package not found; set JSBEEB_PATH");
    return hits[0];
}

const KEY = {
    SHIFT: 16, CTRL: 17, RETURN: 13, SPACE: 32, ESCAPE: 27,
    UP: 38, DOWN: 40, LEFT: 37, RIGHT: 39,
};
for (let i = 0; i < 26; i++) KEY[String.fromCharCode(65 + i)] = 65 + i;
for (let i = 0; i < 10; i++) KEY[String(i)] = 48 + i;

const args = process.argv.slice(2);
function opt(name) {
    const i = args.indexOf(name);
    return i < 0 ? null : args[i + 1];
}
const useTube = args.includes("--tube");
const disc = opt("--disc");
const script = opt("--script") || "waitprompt 30; text";

const root = findJsbeeb();
const { MachineSession } = await import(pathToFileURL(path.join(root, "src/machine-session.js")));
const { findModel } = await import(pathToFileURL(path.join(root, "src/models.js")));

const MODEL = "B-DFS1.2";
if (useTube) findModel(MODEL).tube = findModel("Tube65c02");
else findModel(MODEL).tube = null; // shared instance: undo any prior run's mutation

const session = new MachineSession(MODEL, disc ? { discImage: path.resolve(disc) } : {});
await session.initialise();

const proc = session._machine.processor;
for (const cmd of script.split(";").map((s) => s.trim()).filter(Boolean)) {
    const [op, ...rest] = cmd.split(/\s+/);
    switch (op) {
        case "boot": {
            session.keyDown(KEY.SHIFT);
            session.reset(true);
            await session.runFor(1_500_000);
            session.keyUp(KEY.SHIFT);
            break;
        }
        case "waitprompt": {
            const out = await session.runUntilPrompt(Number(rest[0] || 30));
            process.stdout.write(out.screenText ? out.screenText + "\n" : JSON.stringify(out) + "\n");
            break;
        }
        case "run":
            await session.runFor(Number(rest[0]));
            break;
        case "key": {
            const code = KEY[rest[0].toUpperCase()];
            if (code === undefined) throw new Error("unknown key " + rest[0]);
            if (rest[1] === "down") session.keyDown(code);
            else session.keyUp(code);
            break;
        }
        case "shot": {
            const png = await session.screenshotActive();
            fs.writeFileSync(rest[0], png);
            console.log("wrote", rest[0]);
            break;
        }
        case "mem": {
            const addr = parseInt(rest[0], 16), len = Number(rest[1] || 16);
            const b = session.readMemory(addr, len);
            console.log((b.bytes || b).map((v) => v.toString(16).padStart(2, "0")).join(" "));
            break;
        }
        case "pmem": {
            const addr = parseInt(rest[0], 16), len = Number(rest[1] || 16);
            const par = proc.tube && proc.tube.cpu;
            if (!par) throw new Error("no parasite");
            const out = [];
            for (let i = 0; i < len; i++) out.push(par.readmem(addr + i));
            console.log(out.map((v) => v.toString(16).padStart(2, "0")).join(" "));
            break;
        }
        case "text": {
            const out = session.drainOutput();
            process.stdout.write((out.screenText || "") + "\n");
            break;
        }
        default:
            throw new Error("unknown command " + op);
    }
}
process.exit(0);
