"""MovementSystem: integrates motion and resolves obstacle collisions."""

from std.math import floor
from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    System,
    SystemContext,
)
from storm.components import Acceleration, Position, Velocity
from storm.resources import Bounds, Obstacles, Time


def move_kernel(
    context: KernelContext[
        Filter().include[Position, Velocity].read[Acceleration](),
        Resources[]().read[Time, Bounds, Obstacles](),
    ]
):
    """Integrates motion, resolves obstacle contacts, and wraps at the bounds.

    Sleeping particles have no velocity or acceleration, so they are skipped.

    Args:
        context: Particle rows, timestep, bounds, and obstacles.
    """
    ref time = context.resources.get[Time]()
    ref bounds = context.resources.get[Bounds]()
    ref obstacles = context.resources.get[Obstacles]()
    for particle in context:
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        ref acceleration = particle.get[Acceleration]()
        if (
            velocity.dx == 0
            and velocity.dy == 0
            and acceleration.ddx == 0
            and acceleration.ddy == 0
        ):
            continue
        velocity.dx += acceleration.ddx * time.dt
        velocity.dy += acceleration.ddy * time.dt
        position.x += velocity.dx * time.dt
        position.y += velocity.dy * time.dt
        _ = obstacles.collide(position, velocity, bounds)
        position.x -= floor(position.x / bounds.width) * bounds.width
        position.y -= floor(position.y / bounds.height) * bounds.height


@fieldwise_init
struct MovementSystem[backend: ExecutionBackend](System):
    """Runs movement on the selected execution backend.

    Parameters:
        backend: HOST (threaded) or DEVICE execution for the kernel.
    """

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs the integration kernel.

        Args:
            context: World containing particles, time, and domain bounds.

        Raises:
            Error: If kernel execution fails.
        """
        comptime if Self.backend == ExecutionBackend.DEVICE:
            context.run[move_kernel, backend=Self.backend]()
        else:
            context.run[move_kernel, backend=ExecutionBackend.HOST_THREADED]()
