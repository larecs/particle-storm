"""ContactSystem: resolves contacts between resting particles."""

from std.math import floor, sqrt
from larecs import (
    ExecutionBackend,
    Filter,
    KernelContext,
    Resources,
    System,
    SystemContext,
)
from storm.components import Deposit, Position, Velocity
from storm.resources import (
    Bounds,
    ContactCounts,
    ContactGrid,
    ContactGridRead,
    Obstacles,
)


comptime _FRICTION: Float32 = 0.6
"""Coulomb friction coefficient between particles."""
comptime _SLEEP_PASSES = 12
"""Fewest contact passes a buried particle sleeps."""
comptime _SLEEP_STAGGER = 8
"""Range of extra sleep passes, which spreads wake-ups over frames."""
comptime _SLEEP_PUSH: Float32 = 0.25
"""Largest push, in radii, that still lets a buried particle fall asleep."""


def count_kernel(
    context: KernelContext[
        Filter().read[Position, Velocity, Deposit](),
        Resources[]().write[ContactCounts](),
    ]
):
    """Counts resting particles per cell.

    Obstacles have a Position but no Velocity, so they are not counted.

    Args:
        context: Particle rows and the counts' writer view.
    """
    ref counts = context.resources.get[ContactCounts]()
    for particle in context:
        counts.add(
            particle.get[Position](),
            particle.get[Velocity](),
            particle.get[Deposit](),
        )


def scatter_kernel(
    context: KernelContext[
        Filter().read[Position, Velocity, Deposit](),
        Resources[]().write[ContactGrid](),
    ]
):
    """Stores resting particle positions in their cells' slot ranges.

    Args:
        context: Particle rows and the grid's writer view.
    """
    ref grid = context.resources.get[ContactGrid]()
    for particle in context:
        grid.add(
            particle.get[Position](),
            particle.get[Velocity](),
            particle.get[Deposit](),
        )


@always_inline
def _settle(
    mut position: Position,
    mut velocity: Velocity,
    deposit: Deposit,
    grid: ContactGridRead,
    obstacles: Obstacles,
    seed: Int,
) -> Deposit:
    """Resolves one particle's contacts and returns its new pile state.

    Args:
        position: Particle position in meters, updated in place.
        velocity: Particle velocity in meters per second, updated in place.
        deposit: Particle's pile state from the previous pass.
        grid: Resting particles sorted by cell.
        obstacles: Obstacle shapes.
        seed: Value that differs between particles, such as the row.

    Returns:
        The particle's new pile state.
    """
    if deposit.sleeping():
        return Deposit(deposit.support, deposit.shelter, deposit.sleep - 1)
    var bounds = grid.shape.bounds
    var response = grid.respond(
        position, bounds, grid.shape.resting(velocity, deposit), seed
    )
    var push = response.push
    if push.x != 0 or push.y != 0:
        position.x += push.x
        position.y += push.y
        var length = sqrt(push.x * push.x + push.y * push.y)
        var nx = push.x / length
        var ny = push.y / length
        var normal = velocity.dx * nx + velocity.dy * ny
        if normal < 0:
            velocity.dx -= normal * nx
            velocity.dy -= normal * ny
            # Coulomb friction: the sliding speed drops by at most the
            # friction coefficient times the stopped normal speed.
            var sliding = sqrt(
                velocity.dx * velocity.dx + velocity.dy * velocity.dy
            )
            var keep = max(
                1 - _FRICTION * -normal / max(sliding, 1e-6), Float32(0)
            )
            velocity.dx *= keep
            velocity.dy *= keep
    var pushed = push.x != 0 or push.y != 0
    var supported = False
    # Only slow particles can rest, and only pushed ones can enter an
    # obstacle; movement already resolved the rest.
    if pushed or grid.shape.slow(velocity):
        var on_obstacle = obstacles.collide(
            position, velocity, bounds, grid.shape.radius
        )
        position.x -= floor(position.x / bounds.width) * bounds.width
        position.y -= floor(position.y / bounds.height) * bounds.height
        supported = grid.shape.slow(velocity) and (
            response.touching or on_obstacle
        )
    var settled = _SLEEP_PUSH * grid.shape.radius
    if (
        supported
        and response.shelter >= 1
        and push.x * push.x + push.y * push.y < settled * settled
    ):
        velocity = Velocity(0, 0)
        return Deposit(
            1, response.shelter, Float32(_SLEEP_PASSES + seed % _SLEEP_STAGGER)
        )
    return Deposit.resting(supported, response.shelter)


def contact_kernel(
    context: KernelContext[
        Filter().include[Position, Velocity, Deposit](),
        Resources[]().read[Obstacles, ContactGrid](),
    ]
):
    """Pushes particles out of resting particles, keeps them out of
    obstacles, and updates their pile state.

    Resting particles barely move, so a contact acts like an obstacle
    surface along the push direction: a particle moving into the pile loses
    that velocity, and Coulomb friction slows its sliding in proportion.
    Wind stronger than the friction drags exposed grains along until they
    are fast enough to blow off again. A slow particle
    that touches an obstacle or a resting particle becomes supported and
    joins the grid in the next pass. A fully buried particle that barely
    moved sleeps for a few passes, skipping forces and this search.

    Args:
        context: Particle rows, obstacles, and the grid.
    """
    ref obstacles = context.resources.get[Obstacles]()
    ref grid = context.resources.get[ContactGrid]()
    for particle in context:
        particle.set[Deposit](
            _settle(
                particle.get[Position](),
                particle.get[Velocity](),
                particle.get[Deposit](),
                grid,
                obstacles,
                particle.idx,
            )
        )


struct ContactSystem[backend: ExecutionBackend](System):
    """Resolves overlaps with resting particles after movement.

    Each pass re-sorts the resting particles and resolves half of every
    overlap between them, so more passes make piles stiffer at the cost of
    three kernel runs each.

    Parameters:
        backend: HOST_THREADED or DEVICE execution for the kernels.
    """

    var passes: Int

    def __init__(out self, passes: Int = 2):
        """Creates a contact system.

        Args:
            passes: Grid rebuilds and separation steps per frame.
        """
        self.passes = passes

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Adds a ContactGrid covering the domain and its ContactCounts if
        they are missing.

        Args:
            context: World containing the Bounds resource.

        Raises:
            Error: If Bounds is missing or the grid cannot cover it.
        """
        ref resources = context.world[].resources
        if not resources.has[ContactGrid]():
            resources.add(ContactGrid(resources.read[Bounds]()))
        if not resources.has[ContactCounts]():
            resources.add(ContactCounts(resources.read[ContactGrid]()))

    def update(mut self, mut context: SystemContext[...]) raises:
        """Sorts resting particles into the grid and resolves contacts once
        per pass.

        Args:
            context: World containing particles and the contact resources.

        Raises:
            Error: If a resource is missing or kernel execution fails.
        """
        for _ in range(self.passes):
            context.run[count_kernel, backend=Self.backend]()
            ref resources = context.world[].resources
            resources.get[ContactGrid]().set_counts(
                resources.read[ContactCounts]()
            )
            context.run[scatter_kernel, backend=Self.backend]()
            context.run[contact_kernel, backend=Self.backend]()
