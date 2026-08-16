# Meteor Rush — sample output

Two versions of the same game, both generated end-to-end by **Qwen3.8-27B
running locally** via OpenCode against the server this repo sets up. Same
prompt, one variable changed:

    "create a 3D meteor game using static html. you can create .js files."

| Directory | Server setting |
|---|---|
| `meteor-rush/` | thinking on (default, `reasoning_effort=xhigh`) |
| `meteor-rush-no-thinking/` | `THINKING=0` |

Open either `index.html` directly in a browser — no build step, no CDN, no
Three.js. The 3D is hand-rolled on a 2D canvas: icosahedron subdivision for the
meteors, face normals for shading, and a projection matrix, all written by the
model.

They are here as a **worked example of what this setup produces**, not as
maintained software. The thinking version is ~15% longer (750 vs 650 lines of
`game.js`); judging whether it is better is left to the reader.
