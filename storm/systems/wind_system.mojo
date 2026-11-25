"""WindSystem: accelerates particles toward the local wind."""

from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    System,
    SystemContext,
)
from storm.components import (
    Acceleration,
    Deposit,
    ParticleType,
    Position,
    Velocity,
)
from storm.noise import simplex_noise3
from storm.resources import Bounds, Obstacles, Physics, Storm, Time, Wind


@always_inline
def interference(position: Position, time: Time) -> Wind:
    """Samples small-scale curl-noise gusts at the particle's location.

    Args:
        position: Particle position in meters.
        time: Elapsed simulation time.

    Returns:
        Gust velocity formed by rotating the spatial noise gradient.
    """
    comptime size: Float32 = 5.0
    """Spatial scale of the gusts in meters."""
    comptime strength: Float32 = 7.0
    """Gust velocity scale in meters per second."""
    comptime evolution_time: Float32 = 3.0
    """Seconds per unit of noise-time progression."""
    var sample = simplex_noise3(
        position.x / size, position.y / size, time.absolute / evolution_time
    )
    return Wind(strength * sample.dy, -strength * sample.dx)


def wind_kernel(
    context: KernelContext[
        Filter()
        .write[Acceleration]
        .read[Position, Velocity, ParticleType, Deposit](),
        Resources[]().read[Time, Physics, Bounds, Storm, Obstacles](),
    ]
):
    """Computes acceleration from gravity and drag toward the local wind.

    The wind is the storm vortex plus small-scale gusts, bent around the
    obstacles and weakened inside piles of resting particles.

    Args:
        context: Particle rows and read-only simulation parameters.
    """
    ref time = context.resources.get[Time]()
    ref physics = context.resources.get[Physics]()
    ref bounds = context.resources.get[Bounds]()
    ref storm = context.resources.get[Storm]()
    ref obstacles = context.resources.get[Obstacles]()
    var center = storm.center(time.absolute, bounds)
    for particle in context:
        if particle.get[Deposit]().sleeping():
            particle.set[Acceleration](Acceleration(0, 0))
            continue
        ref position = particle.get[Position]()
        ref velocity = particle.get[Velocity]()
        var vortex = storm.wind(position, center, bounds)
        var gust = interference(position, time)
        var wind = obstacles.deflect(
            Wind(vortex.dx + gust.dx, vortex.dy + gust.dy), position, bounds
        )
        var exposure = 1 - particle.get[Deposit]().shelter
        var response = physics.response_times[particle.get[ParticleType]().id]
        particle.set[Acceleration](
            Acceleration(
                (exposure * wind.dx - velocity.dx) / response,
                (exposure * wind.dy - velocity.dy) / response,
            )
        )


@fieldwise_init
struct WindSystem[backend: ExecutionBackend](System):
    """Runs wind acceleration on the selected execution backend.

    Parameters:
        backend: HOST (threaded) or DEVICE execution for the kernel.
    """

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs the wind kernel.

        Args:
            context: World containing particles and wind parameters.

        Raises:
            Error: If kernel execution fails.
        """
        comptime if Self.backend == ExecutionBackend.DEVICE:
            context.run[wind_kernel, backend=Self.backend]()
        else:
            context.run[wind_kernel, backend=ExecutionBackend.HOST_THREADED]()
