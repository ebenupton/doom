// Headless jsbeeb harness that MEASURES the display instead of eyeballing it.
//
// Every earlier attempt to pin down the screen-start offset read pixel
// coordinates off a screenshot by eye, and the probe window and the game
// window sit at different places on the raster, so those readings were
// not comparable. This renders into jsbeeb's own framebuffer and reports
// numbers: the bounding box of lit pixels, and — given the staircase
// pattern the probe paints — which framebuffer cell is displayed first.
//
//   node tools/crtc_measure.mjs <disc.ssd> <cycles> [--halt=ADDR]
//
// --halt patches an infinite loop at ADDR (hex) once reached, freezing
// the CPU so a running game cannot clear or flip the buffer underneath
// the measurement.
import { fake6502 } from "/Users/ebenupton/jsbeeb/src/fake6502.js";
import { findModel } from "/Users/ebenupton/jsbeeb/src/models.js";
import { Video } from "/Users/ebenupton/jsbeeb/src/video.js";
import * as fdc from "/Users/ebenupton/jsbeeb/src/fdc.js";
import * as utils from "/Users/ebenupton/jsbeeb/src/utils.js";
import fs from "fs";

// --bin=FILE injects a raw binary at --org and jumps to it once the OS
// has settled, bypassing DFS entirely (the *EXEC autoboot did not fire
// reliably headless, and DFS is not what we are measuring).
const [discPath, cyclesArg, ...rest] = process.argv.slice(2);
const binArg = rest.find((a) => a.startsWith("--bin="));
const orgArg = rest.find((a) => a.startsWith("--org="));
const binPath = binArg ? binArg.split("=")[1] : null;
const org = orgArg ? parseInt(orgArg.split("=")[1], 16) : 0x1900;
const cycles = Number(cyclesArg || 60e6);
const haltArg = rest.find((a) => a.startsWith("--halt="));
const haltAddr = haltArg ? parseInt(haltArg.split("=")[1], 16) : null;

const WIDTH = 1024;   // jsbeeb's Video hardcodes a 1024-pixel stride
const HEIGHT = 768;   // (see src/video.js: y * 1024 + x, 625 lines used)
const fb32 = new Uint32Array(WIDTH * HEIGHT);
let lastPaint = null;
const video = new Video(false, fb32, (minx, miny, maxx, maxy) => {
    lastPaint = { minx, miny, maxx, maxy };
});

const cpu = fake6502(findModel("B-DFS1.2"), { video });
await cpu.initialise();

if (discPath && discPath !== "-") {
    const data = new Uint8Array(fs.readFileSync(discPath));
    cpu.fdc.loadDisc(0, fdc.discFor(cpu.fdc, "", data));
}

// Shift-break autoboot: the OS samples SHIFT during the first
// milliseconds AFTER the reset, so press it once the reset has been
// issued (pressing before reset() loses the key state).
cpu.sysvia.keyDown(utils.BBC.SHIFT);
cpu.reset(true);
let done = 0;
const chunk = 100000;
let holdReleased = false;
let halted = false;
let injected = false;
while (done < cycles) {
    cpu.execute(chunk);
    done += chunk;
    if (!holdReleased && done > 6e6) {
        cpu.sysvia.keyUp(utils.BBC.SHIFT);
        holdReleased = true;
    }
    if (binPath && !injected && done > 12e6) {
        const bin = new Uint8Array(fs.readFileSync(binPath));
        for (let i = 0; i < bin.length; i++) cpu.writemem(org + i, bin[i]);
        cpu.pc = org;
        injected = true;
    }
    if (haltAddr !== null && !halted && done > cycles * 0.8) {
        // patch JMP <self> so the frame loop stops where it is
        cpu.writemem(haltAddr, 0x4c);
        cpu.writemem(haltAddr + 1, haltAddr & 0xff);
        cpu.writemem(haltAddr + 2, haltAddr >>> 8);
        halted = true;
    }
}

// --- measure the rendered framebuffer -------------------------------
let minx = 1e9, miny = 1e9, maxx = -1, maxy = -1, lit = 0;
for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
        const p = fb32[y * WIDTH + x] & 0x00ffffff;
        if (p !== 0) {
            lit++;
            if (x < minx) minx = x;
            if (x > maxx) maxx = x;
            if (y < miny) miny = y;
            if (y > maxy) maxy = y;
        }
    }
}
console.log(JSON.stringify({ lit, minx, maxx, miny, maxy, lastPaint,
    pc: cpu.pc.toString(16), crtc: Array.from(video.regs.slice(0, 16)).map((v) => v.toString(16)) }));

// The probe's staircase: cell c is a solid block in row c. Find each
// block's (x,y) so the caller can see which step is leftmost/topmost.
// Blocks are 8 CRTC pixels wide and 8 rasters tall; jsbeeb renders one
// CRTC pixel per fb column in 1bpp modes at this scale.
const blocks = [];
const seen = new Set();
for (let y = miny; y <= maxy; y++) {
    for (let x = minx; x <= maxx; x++) {
        if ((fb32[y * WIDTH + x] & 0x00ffffff) === 0) continue;
        const key = `${Math.floor(x / 4)},${Math.floor(y / 4)}`;
        if (seen.has(key)) continue;
        // a block: 8 consecutive lit pixels horizontally AND vertically
        let runx = 0;
        while (x + runx <= maxx && (fb32[y * WIDTH + x + runx] & 0x00ffffff) !== 0) runx++;
        let runy = 0;
        while (y + runy <= maxy && (fb32[(y + runy) * WIDTH + x] & 0x00ffffff) !== 0) runy++;
        if (runx >= 6 && runy >= 6) {
            blocks.push({ x, y, runx, runy });
            for (let dy = 0; dy < runy; dy++)
                for (let dx = 0; dx < runx; dx++) seen.add(`${Math.floor((x + dx) / 4)},${Math.floor((y + dy) / 4)}`);
        }
    }
}
blocks.sort((a, b) => a.y - b.y || a.x - b.x);
console.log("blocks:", JSON.stringify(blocks.slice(0, 24)));
const peek = (a) => cpu.readmem(a).toString(16).padStart(2, "0");
console.log("fb $5800:", [0, 1, 2, 3, 4, 5, 6, 7].map((i) => peek(0x5800 + i)).join(" "));
console.log("fb $5908:", [0, 1, 2, 3, 4, 5, 6, 7].map((i) => peek(0x5908 + i)).join(" "));
console.log("fb $5A10:", [0, 1, 2, 3, 4, 5, 6, 7].map((i) => peek(0x5a10 + i)).join(" "));
console.log("ula ctrl/pal readback not available; video.regs above");

// ASCII map of the lit area, one char per 8x8 fb pixels, so the layout
// is countable rather than eyeballed.
const x0 = Math.max(0, minx), x1 = Math.min(WIDTH - 1, maxx);
const y0 = Math.max(0, miny), y1 = Math.min(HEIGHT - 1, maxy);
console.log(`map x:${x0}..${x1} y:${y0}..${y1}`);
for (let y = y0; y <= y1; y += 4) {
    let line = "";
    for (let x = x0; x <= x1; x += 8) {
        let n = 0;
        for (let dy = 0; dy < 4; dy++)
            for (let dx = 0; dx < 8; dx++) {
                const yy = y + dy, xx = x + dx;
                if (yy <= y1 && xx <= x1 && (fb32[yy * WIDTH + xx] & 0x00ffffff) !== 0) n++;
            }
        line += n === 0 ? "." : n >= 24 ? "#" : n >= 8 ? "+" : "-";
    }
    console.log(String(y).padStart(4) + " " + line);
}
