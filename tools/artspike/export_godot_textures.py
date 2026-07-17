"""Export the lightspike textures for the Godot toy scene: flat albedo +
normal map for the kx6 at heading 0. Normal map is encoded in OpenGL
convention (green = Y-up), which is what Godot's CanvasTexture expects;
lightspike's arrays are image-space (Y-down), so green gets flipped.

Run:  python export_godot_textures.py   (writes into godot/)
"""
import pathlib

import numpy as np
from PIL import Image

import lightspike as L


def main():
    out = pathlib.Path(__file__).parent / "godot"
    out.mkdir(exist_ok=True)

    rgba = L.render_frame(0)
    offsets, emissive = L.classify(rgba[..., :3], rgba[..., 3])
    flat = L.flatten_albedo(rgba, rgba[..., 3])
    height, solid = L.build_height(flat[..., 3], offsets, emissive)
    normals = L.height_to_normals(height, z_scale=28.0)

    albedo = (np.clip(flat, 0, 1) * 255).astype(np.uint8)
    Image.fromarray(albedo, "RGBA").save(out / "kx6_albedo.png")

    n = normals.copy()
    n[..., 1] *= -1.0                       # image Y-down -> GL Y-up
    n[solid < 0.5] = [0.0, 0.0, 1.0]        # background: flat, facing camera
    enc = ((n + 1.0) / 2.0 * 255).astype(np.uint8)
    Image.fromarray(enc, "RGB").save(out / "kx6_normal.png")
    print("wrote", out / "kx6_albedo.png", "and kx6_normal.png",
          albedo.shape[1], "x", albedo.shape[0])


if __name__ == "__main__":
    main()
