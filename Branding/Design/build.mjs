// Expands <!--ICON:size:variant--> and <!--MARK:size:ink:orange:paper--> markers
// in *.tpl.html into the .dc.html artboards, so the one icon drawing is shared.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';

// Fine grooves between the three deep ones.
const fineRings = () => {
  let s = '';
  for (let r = 176; r <= 366; r += 12) s += `<circle cx="512" cy="512" r="${r}"/>`;
  return s;
};

// variant: full | dark | clear | tinted | l1 | l2 | l3  (l = Icon Composer layers)
let iconSeq = 0;
function icon(size, variant = 'full') {
  const v = variant;
  const uid = `i${++iconSeq}`;
  const layer = (n) => v === 'full' || v === 'dark' || v === `l${n}`;
  const mono = v === 'clear' || v === 'tinted';
  const chassisFill = v === 'dark' ? 'url(#cd-chassis-dark)' : 'url(#cd-chassis)';
  let body = '';
  if (mono) {
    const tint = v === 'tinted';
    body += `<rect width="1024" height="1024" fill="${tint ? '#5B6B93' : '#B9C6D2'}" fill-opacity="${tint ? '.9' : '.55'}"/>`;
    body += `<rect x="4" y="4" width="1016" height="1016" rx="224" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="8"/>`;
    body += `<circle cx="512" cy="512" r="380" fill="#fff" fill-opacity=".30"/>`;
    body += `<circle cx="512" cy="512" r="376" fill="none" stroke="#fff" stroke-opacity=".7" stroke-width="8"/>`;
    body += `<circle cx="512" cy="512" r="300" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10"/>`;
    body += `<circle cx="512" cy="512" r="220" fill="none" stroke="#fff" stroke-opacity=".45" stroke-width="10"/>`;
    body += `<circle cx="512" cy="512" r="150" fill="#fff" fill-opacity=".92"/>`;
    body += `<circle cx="512" cy="512" r="22" fill="#5B6B93" fill-opacity="${tint ? '1' : '.6'}"/>`;
  } else {
    if (layer(1)) {
      body += `<rect width="1024" height="1024" fill="${chassisFill}"/>`;
      body += `<rect width="1024" height="1024" fill="url(#cd-sheen)"/>`;
      body += `<rect x="2" y="2" width="1020" height="1020" rx="226" fill="none" stroke="#fff" stroke-opacity=".14" stroke-width="4"/>`;
    }
    if (layer(2)) {
      body += `<circle cx="512" cy="512" r="380" fill="url(#cd-vinyl)"/>`;
      body += `<g fill="none" stroke="#F5F1E6" stroke-opacity=".035" stroke-width="3">${fineRings()}</g>`;
      body += `<circle cx="512" cy="512" r="300" fill="none" stroke="#F5F1E6" stroke-opacity=".12" stroke-width="10"/>`;
      body += `<circle cx="512" cy="512" r="220" fill="none" stroke="#F5F1E6" stroke-opacity=".12" stroke-width="10"/>`;
      body += `<circle cx="512" cy="512" r="380" fill="url(#cd-vinylsheen)"/>`;
      body += `<circle cx="512" cy="512" r="378" fill="none" stroke="#fff" stroke-opacity=".14" stroke-width="4"/>`;
    }
    if (layer(3)) {
      body += `<circle cx="512" cy="512" r="150" fill="url(#cd-label)"/>`;
      body += `<circle cx="512" cy="512" r="148" fill="none" stroke="#000" stroke-opacity=".10" stroke-width="3"/>`;
      body += `<circle cx="512" cy="512" r="22" fill="#FF6D3F"/>`;
    }
  }
  return `<svg viewBox="0 0 1024 1024" width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg" style="display:block;flex:none">
<defs>
<linearGradient id="cd-chassis" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FF8A5C"/><stop offset=".55" stop-color="#FF6D3F"/><stop offset="1" stop-color="#E5552B"/></linearGradient>
<linearGradient id="cd-chassis-dark" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#E8603A"/><stop offset=".55" stop-color="#D94C25"/><stop offset="1" stop-color="#B83D1C"/></linearGradient>
<radialGradient id="cd-sheen" cx=".3" cy=".1" r=".9"><stop offset="0" stop-color="#fff" stop-opacity=".18"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient>
<radialGradient id="cd-vinyl" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#1B2026"/><stop offset=".6" stop-color="#0C0F13"/><stop offset="1" stop-color="#05070A"/></radialGradient>
<linearGradient id="cd-vinylsheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".12"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/><stop offset=".75" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#fff" stop-opacity=".05"/></linearGradient>
<linearGradient id="cd-label" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#FFFDF7"/><stop offset="1" stop-color="#EDE6D6"/></linearGradient>
<clipPath id="cd-mask"><rect width="1024" height="1024" rx="228"/></clipPath>
</defs>
<g clip-path="url(#cd-mask)">${body}</g>
</svg>`.replace(/cd-([a-z-]+)/g, (_, n) => `cd-${n}-${uid}`);
}

// The flat glyph the wordmark uses. ink / orange / paper are colours.
let markSeq = 0;
function mark(size, ink, orange, paper) {
  // The gap between disc and panel is cut out of the disc, not painted, so the
  // mark sits on any surface. Ink spans y 1.5 to 22.2 of the 24 grid (86% of
  // the box); the lockups size the box at 0.807 x the type size so that ink
  // equals Major Mono's cap height (0.696 em), and nudge it down 0.072 x box
  // so its centre meets the caps' centre (0.552 em below the line box top).
  const uid = `m${++markSeq}`;
  const top = Math.round(size * 0.072);
  return `<svg viewBox="0 0 24 24" width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg" style="display:block;flex:none;position:relative;top:${top}px">
<defs><clipPath id="cd-gap-${uid}"><rect x="0" y="0" width="24" height="15"/></clipPath></defs>
<circle cx="12" cy="10.5" r="9" fill="${ink}" clip-path="url(#cd-gap-${uid})"/>
<circle cx="12" cy="10.5" r="3.1" fill="${orange}"/>
<rect x="1" y="16.6" width="22" height="5.6" rx="1.6" fill="${ink}"/>
</svg>`;
}

for (const f of readdirSync('.')) {
  if (!f.endsWith('.tpl.html')) continue;
  let html = readFileSync(f, 'utf8');
  html = html.replace(/<!--ICON:(\d+)(?::(\w+))?-->/g, (_, s, v) => icon(+s, v || 'full'));
  html = html.replace(/<!--MARK:(\d+):([^:]+):([^:]+):([^-]+)-->/g, (_, s, i, o, p) => mark(+s, i, o, p));
  const out = f.replace('.tpl.html', '.dc.html');
  writeFileSync(out, html);
  console.log('wrote', out);
}

// About · Light: the same faceplate with the Carbon light tokens swapped in.
const LIGHT = [
  ['background: #080A0E', 'background: #DCE9EC'],
  ['#171C22; background-image: linear-gradient(180deg, rgba(255,255,255,.05), rgba(255,255,255,0) 50%, rgba(0,0,0,.22)), linear-gradient(135deg, rgba(43,53,64,.28), rgba(23,28,34,.30), rgba(12,15,19,.36)); box-shadow: inset 0 0 0 1px rgba(255,255,255,.10), 0 24px 54px rgba(0,0,0,.72)',
   '#F5F8FA; background-image: linear-gradient(180deg, rgba(255,255,255,.42), rgba(255,255,255,0) 50%, rgba(0,0,0,.05)), linear-gradient(135deg, rgba(255,255,255,.54), rgba(245,248,250,.44), rgba(215,225,229,.34)); box-shadow: inset 0 0 0 1px rgba(199,210,215,.7), 0 22px 48px rgba(13,13,13,.24)'],
  ['#121A22; background-image: linear-gradient(135deg, rgba(18,26,34,.42), rgba(7,10,14,.42)); box-shadow: inset 0 0 0 1px rgba(255,255,255,.12), inset 0 1px 2px rgba(0,0,0,.30), 0 8px 18px rgba(0,0,0,.46)',
   '#E9F1F4; background-image: linear-gradient(135deg, rgba(233,241,244,.58), rgba(200,213,218,.42)); box-shadow: inset 0 0 0 1px rgba(199,210,215,.72), inset 0 1px 2px rgba(0,0,0,.08), 0 8px 18px rgba(0,0,0,.14)'],
  ['#303A43; background-image: linear-gradient(135deg, rgba(86,98,107,.42), rgba(48,58,67,.34), rgba(21,26,32,.42)); box-shadow: inset 0 0 0 .7px rgba(255,255,255,.16), 0 2px 5px rgba(0,0,0,.48)',
   '#DDE8EC; background-image: linear-gradient(135deg, rgba(255,255,255,.68), rgba(221,232,236,.46), rgba(171,185,192,.38)); box-shadow: inset 0 0 0 .7px rgba(255,255,255,.70), 0 2px 5px rgba(0,0,0,.14)'],
  ['#C8D4D9', '#313E47'],
  ['#F3F7F7', '#12171C'],
  ['#56636C', '#98A5AB'],
  ['rgba(69,199,189', 'rgba(58,168,184'],
  ['#45C7BD', '#3AA8B8'],
  ['rgba(255,109,63', 'rgba(255,98,54'],
  ['#FF6D3F', '#FF6236'],
  ['rgba(244,202,84', 'rgba(244,200,74'],
  ['#F4CA54', '#F4C84A'],
  ['rgba(114,130,232', 'rgba(75,111,203'],
  ['#7282E8', '#4B6FCB'],
  ['#050504', '#0A0A0A'],
  ['#0E0E0C', '#1A1A1A'],
  ['rgba(38,51,60,.5)', 'rgba(199,210,215,.7)'],
  ['#121A22-->', '#E9F1F4-->'],
];
{
  let html = readFileSync('About.tpl.html', 'utf8');
  for (const [from, to] of LIGHT) {
    if (!html.includes(from)) console.warn('light map: no match for', from.slice(0, 40));
    html = html.split(from).join(to);
  }
  html = html.replace(/<!--ICON:(\d+)(?::(\w+))?-->/g, (_, s, v) => icon(+s, v || 'full'));
  html = html.replace(/<!--MARK:(\d+):([^:]+):([^:]+):([^-]+)-->/g, (_, s, i, o, p) => mark(+s, i, o, p));
  writeFileSync('AboutLight.dc.html', html);
  console.log('wrote AboutLight.dc.html');
}
