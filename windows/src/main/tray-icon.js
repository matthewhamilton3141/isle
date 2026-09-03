// tray-icon.js
//
// Isle's tray glyph: the 3×3 dot mark, rasterised straight into a BGRA bitmap
// so no image asset has to ship. White on a dark taskbar, black on a light
// one — the Windows stand-in for a macOS template image.

const { nativeImage } = require('electron');

function render(side, dark) {
  const buffer = Buffer.alloc(side * side * 4);
  const inset = side * 0.1;
  const box = side - inset * 2;
  const d = box * 0.26;
  const step = (box - d) / 2;
  const radius = d / 2;
  const shade = dark ? 255 : 0;
  const centres = [];
  for (let row = 0; row < 3; row++) {
    for (let col = 0; col < 3; col++) {
      centres.push([inset + col * step + radius, inset + row * step + radius]);
    }
  }
  // 4× supersampled coverage per pixel for smooth edges at 16px.
  for (let y = 0; y < side; y++) {
    for (let x = 0; x < side; x++) {
      let coverage = 0;
      for (let sy = 0; sy < 4; sy++) {
        for (let sx = 0; sx < 4; sx++) {
          const px = x + (sx + 0.5) / 4;
          const py = y + (sy + 0.5) / 4;
          if (centres.some(([cx, cy]) => (px - cx) ** 2 + (py - cy) ** 2 <= radius * radius)) coverage++;
        }
      }
      const alpha = Math.round((coverage / 16) * 255);
      const offset = (y * side + x) * 4;
      // Premultiplied BGRA.
      const value = Math.round((shade * alpha) / 255);
      buffer[offset] = value;
      buffer[offset + 1] = value;
      buffer[offset + 2] = value;
      buffer[offset + 3] = alpha;
    }
  }
  return buffer;
}

function trayIcon(dark) {
  const image = nativeImage.createFromBitmap(render(16, dark), { width: 16, height: 16, scaleFactor: 1 });
  image.addRepresentation({ width: 32, height: 32, scaleFactor: 2, buffer: render(32, dark) });
  return image;
}

module.exports = { trayIcon };
