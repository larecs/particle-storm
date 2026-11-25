"""GravitySystem: adds gravity to awake particles."""

from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    System,
    SystemContext,
)
from storm.components import Acceleration, Deposit
from storm.resources import Physics


def gravity_kernel(
    context: KernelContext[
        Filter().include[Acceleration].read[Deposit](),
        Resources[]().read[Physics](),
    ]
):
    """Adds gravity to every particle that is not asleep in a pile.

    Args:
        context: Particle rows and the physics parameters.
    """
    ref physics = context.resources.get[Physics]()
    for particle in context:
        if not particle.get[Deposit]().sleeping():
            particle.get[Acceleration]().ddy += physics.gravity


@fieldwise_init
struct GravitySystem[backend: ExecutionBackend](System):
    """Runs gravity acceleration on the selected execution backend.

    Parameters:
        backend: HOST_THREADED or DEVICE execution for the kernel.
    """

    def update(mut self, mut context: SystemContext[...]) raises:
        """Runs the gravity kernel.

        Args:
            context: World containing particles and wind parameters.

        Raises:
            Error: If kernel execution fails.
        """
        context.run[gravity_kernel, backend=Self.backend]()
