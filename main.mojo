"""Interactive SDL3 particle storm; pass --gpu or --frames N for bounded runs."""

from std.sys import has_accelerator, num_physical_cores
from larecs import ExecutionBackend, Scheduler, ThreadedExecutionConfig, World
from storm.components import (
    Acceleration,
    Deposit,
    Obstacle,
    ParticleType,
    Position,
    Velocity,
)
from storm.options import Options
from storm.resources import Bounds, Physics, RunState, Storm, Time
from storm.scene import add_default_obstacles, add_particles
from storm.systems import (
    ContactSystem,
    DisplaySystem,
    EditorSystem,
    GravitySystem,
    MovementSystem,
    ObstacleSystem,
    TimeSystem,
    WindSystem,
)


def main() raises:
    """Runs the particle simulation until the window closes or frames expire.

    Raises:
        Error: If arguments are invalid, or simulation or display setup fails.
    """
    var options = Options.parse()
    var world = World[
        Position, Velocity, Acceleration, ParticleType, Deposit, Obstacle
    ](
        execution_config=ThreadedExecutionConfig(
            workers=num_physical_cores(), min_parallel_rows=8192
        )
    )
    # Keeps unchanged columns on the device between GPU kernel runs.
    world.reuse_device_copies(options.on_gpu)
    world.resources.add(
        Time(), Bounds(), RunState(), Physics(snow=0.2, sand=0.8), Storm()
    )
    add_default_obstacles(world)
    add_particles(world, options.particles)

    var scheduler = Scheduler(world^)
    scheduler.add_system(TimeSystem(frame_limit=options.frames))
    scheduler.add_system(EditorSystem())
    scheduler.add_system(ObstacleSystem())
    if options.on_gpu:
        comptime if has_accelerator():
            scheduler.add_system(WindSystem[ExecutionBackend.DEVICE]())
            scheduler.add_system(MovementSystem[ExecutionBackend.DEVICE]())
            scheduler.add_system(ContactSystem[ExecutionBackend.DEVICE]())
            scheduler.add_system(DisplaySystem[ExecutionBackend.DEVICE]())
            print("Simulation backend: GPU")
        else:
            raise Error("--gpu requires an available accelerator")
    else:
        scheduler.add_system(WindSystem[ExecutionBackend.HOST_THREADED]())
        scheduler.add_system(GravitySystem[ExecutionBackend.HOST_THREADED]())
        scheduler.add_system(MovementSystem[ExecutionBackend.HOST_THREADED]())
        scheduler.add_system(ContactSystem[ExecutionBackend.HOST_THREADED]())
        scheduler.add_system(DisplaySystem[ExecutionBackend.HOST_THREADED]())
        print("Simulation backend: CPU")
    scheduler.initialize()
    while scheduler.world.resources.get[RunState]().running:
        scheduler.update()
    var completed = scheduler.world.resources.get[RunState]().frames
    scheduler.finalize()
    print("Displayed", completed, "frames with", options.particles, "particles")
