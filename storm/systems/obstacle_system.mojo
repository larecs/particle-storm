"""ObstacleSystem: publishes obstacle entities to the Obstacles resource."""

from larecs import Filter, System, SystemContext
from storm.components import Obstacle, Position
from storm.resources import Obstacles


@fieldwise_init
struct ObstacleSystem(System):
    """Packs obstacle entities into the Obstacles resource that kernels read.

    The resource is replaced only when an obstacle was added, removed, moved,
    or resized, so unchanged frames keep its device copy.
    """

    def initialize(mut self, mut context: SystemContext[...]) raises:
        """Packs the initial obstacles.

        Args:
            context: World containing obstacle entities.

        Raises:
            Error: If there are more than MAX_OBSTACLES obstacles.
        """
        self.update(context)

    def update(mut self, mut context: SystemContext[...]) raises:
        """Repacks obstacles and publishes them if they changed.

        Args:
            context: World containing obstacle entities.

        Raises:
            Error: If there are more than MAX_OBSTACLES obstacle shapes, or
                a shape is invalid.
        """
        ref resources = context.world[].resources
        var packed = Obstacles()
        var present = resources.has[Obstacles]()
        if present:
            packed.friction = resources.read[Obstacles]().friction
        for entity in context.world[].storage.query[
            Filter().read[Position, Obstacle]()
        ]():
            ref position = entity.get[Position]()
            packed.add(position, entity.get[Obstacle]())
        if not present:
            resources.add(packed)
        elif not resources.read[Obstacles]().same_shapes(packed):
            resources.set(packed)
