# Particle storm

Run a Larecs particle simulation with an SDL3 window. Snow appears pale blue
and sand appears amber. One large storm vortex drifts through a periodic
domain while small-scale gusts break up its flow; gravity pulls the particles
down. Wind bends around gray obstacles, and particles that hit one slide
along its surface. The top-left corner shows the frame rate.

Install [Pixi](https://pixi.sh/) and run from this checkout:

```sh
pixi run --locked particles
```

Pixi builds Larecs `1.0.0b2` from the pinned upstream release candidate.
The lockfile records its source revision for macOS ARM64 and Linux x86-64.

The simulation uses the CPU by default. Pass `--gpu` to use an available
accelerator. Close the window or press Escape to exit. A Larecs kernel
rasterizes the particles into a framebuffer resource on the selected backend,
and SDL shows the image as a texture. On the CPU, kernels run on all physical
cores. Obstacles are entities with `Position` and `Obstacle` components. Because
kernels iterate particles only, `ObstacleSystem` packs them into a small
resource each frame, so moving, adding, or removing one takes effect on the
next frame.

`ObstacleBuilder` composes an obstacle from circles and rectangles placed at
offsets from a shared origin. Rotating the builder turns all parts together,
and each rectangle can add its own rotation. Each part becomes one entity:

```mojo
_ = (
    ObstacleBuilder(62, 30, angle=0.35)
    .rectangle(0, 0, width=22, height=3)
    .circle(-11, 0, radius=2.5)
    .circle(11, 0, radius=2.5)
    .spawn(world)
)
```

Edit obstacles with the mouse while the simulation runs:

| Input | Action |
| --- | --- |
| `1` / `2` | Choose the circle or rectangle tool |
| Left click on empty space | Add a shape and drag it into place |
| Left drag on an obstacle | Move the whole obstacle |
| Mouse wheel | Resize the obstacle under the cursor |
| `Q` / `E` held | Rotate the obstacle under the cursor |
| Right click or Delete | Remove the obstacle under the cursor |

The display records each frame's mouse and keyboard input in the `Input`
resource. `EditorSystem` applies it to the obstacle entities at the start of
the next frame, and edits a builder obstacle as one group.

Slow particles that touch an obstacle or a pile come to rest and collide with
each other. `ContactSystem` sorts the resting particles into a uniform grid
with a counting sort, then pushes each particle out of its overlapping
neighbors. Airborne particles bounce off piles but pass through each other.
Piles shelter the particles inside them from the wind, and fully buried
particles sleep for a few frames, skipping forces and the neighbor search.

A world holds at most 16 shapes. Wind and collisions use each shape's signed
distance; for circles, the wind matches potential flow past a cylinder.

```sh
pixi run particles --gpu
pixi run particles --particles 1000000 --frames 300
pixi run test       # all tests
pixi run smoke      # build, then run 30 headless frames
pixi run format
```

The simulation advances by the real time between frames, capped at 0.1
seconds, and renders at most 60 frames per second. The window preserves
the domain's aspect ratio when resized. The display test uses SDL's dummy video
driver and needs no desktop session.

## Layout

Each component, resource, and system has its own file, named after the type.

| Path | Contents |
| --- | --- |
| `main.mojo` | Creates the world and schedules the systems |
| `storm/components/` | `Position`, `Velocity`, `Acceleration`, `ParticleType`, `Deposit`, `Obstacle` |
| `storm/resources/` | `Time`, `Bounds`, `RunState`, `Physics`, `Storm`, `Obstacles`, `ContactGrid`, `Framebuffer`, `Input`, `Editor` |
| `storm/systems/` | One `<name>_system.mojo` per system, with its kernels |
| `storm/scene/` | `ObstacleBuilder` and the default obstacles |
| `storm/noise.mojo`, `storm/periodic.mojo` | Simplex noise and periodic distances |
| `storm/options.mojo` | Command-line options |
| `tests/` | Tests |
